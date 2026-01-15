import Foundation
import Synchronization

@_exported import Peer
import PeerGRPC

/// A high-level P2P node abstraction that manages server and client connections.
///
/// `PeerNode` provides a simple API for P2P communication without exposing
/// the underlying transport implementation details (gRPC, sockets, etc.).
///
/// ## Usage
///
/// ```swift
/// import PeerNode
///
/// // Create and start a node
/// let node = PeerNode(name: "alice", host: "127.0.0.1", port: 0)
/// try await node.start()
/// print("Listening on port \(node.boundPort!)")
///
/// // Handle incoming connections
/// Task {
///     for await connection in node.incomingConnections {
///         print("Connected: \(connection.peerID)")
///     }
/// }
///
/// // Advertise on local network
/// try await node.advertise()
///
/// // Discover peers on local network
/// for try await peer in node.discover(timeout: .seconds(5)) {
///     print("Found: \(peer.name)")
///     try await node.connect(to: peer.peerID)
/// }
///
/// // Connect to another peer manually
/// let bob = PeerID("bob@192.168.1.10:50052")!
/// try await node.connect(to: bob)
///
/// // Get transport for messaging
/// if let transport = node.transport(for: bob) {
///     try await transport.send(envelope)
/// }
///
/// // Cleanup
/// await node.stop()
/// ```
///
public final class PeerNode: @unchecked Sendable {

    // MARK: - Transport Type

    /// The underlying transport implementation to use.
    public enum Transport: Sendable {
        /// gRPC over HTTP/2 (default)
        case grpc
    }

    // MARK: - State

    private enum NodeState: Sendable {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    private struct MutableState: ~Copyable {
        var state: NodeState = .idle
        var server: GRPCServer?
        var routes: [String: any DistributedTransport] = [:]  // key: host:port
        var peerIDs: [String: PeerID] = [:]  // key: host:port -> full PeerID
        var acceptTask: Task<Void, Never>?
        var isAdvertising: Bool = false
    }

    // MARK: - Properties

    private let name: String
    private let host: String
    private let requestedPort: Int
    private let transport: Transport
    private let serviceType: String
    private let mutableState: Mutex<MutableState>
    private let discovery: LocalNetworkDiscovery

    private let incomingStream: AsyncStream<IncomingConnection>
    private let incomingContinuation: AsyncStream<IncomingConnection>.Continuation

    // MARK: - Public Properties

    /// The local peer ID for this node.
    public var localPeerID: PeerID {
        let port = boundPort ?? requestedPort
        return PeerID(name: name, host: host, port: port)
    }

    /// The port the node is bound to after starting.
    /// Returns nil if the node has not been started.
    public var boundPort: Int? {
        mutableState.withLock { $0.server?.boundPort }
    }

    /// Stream of incoming connections from remote peers.
    public var incomingConnections: AsyncStream<IncomingConnection> {
        incomingStream
    }

    /// List of currently connected peer IDs.
    public var connectedPeers: [PeerID] {
        mutableState.withLock { state in
            Array(state.peerIDs.values)
        }
    }

    // MARK: - Initialization

    /// The default Bonjour service type for community nodes.
    public static let defaultServiceType = "_community._tcp"

    /// Creates a new PeerNode.
    ///
    /// - Parameters:
    ///   - name: The display name for this node.
    ///   - host: The host address to bind to. Defaults to "127.0.0.1".
    ///   - port: The port to listen on. Use 0 for automatic assignment.
    ///   - transport: The transport implementation to use. Defaults to `.grpc`.
    ///   - serviceType: The Bonjour service type for discovery. Defaults to `_community._tcp`.
    public init(
        name: String,
        host: String = "127.0.0.1",
        port: Int = 0,
        transport: Transport = .grpc,
        serviceType: String = PeerNode.defaultServiceType
    ) {
        self.name = name
        self.host = host
        self.requestedPort = port
        self.transport = transport
        self.serviceType = serviceType
        self.mutableState = Mutex(MutableState())
        self.discovery = LocalNetworkDiscovery(serviceType: serviceType)

        var continuation: AsyncStream<IncomingConnection>.Continuation!
        self.incomingStream = AsyncStream { cont in
            continuation = cont
        }
        self.incomingContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Starts the node and begins accepting connections.
    ///
    /// - Throws: `PeerNodeError.alreadyStarted` if already running,
    ///           `PeerNodeError.portUnavailable` if the port is in use,
    ///           `PeerNodeError.startFailed` for other failures.
    public func start() async throws {
        let canStart = mutableState.withLock { state -> Bool in
            guard state.state == .idle else { return false }
            state.state = .starting
            return true
        }

        guard canStart else {
            let currentState = mutableState.withLock { $0.state }
            if currentState == .stopped {
                throw PeerNodeError.alreadyStopped
            }
            throw PeerNodeError.alreadyStarted
        }

        do {
            try await startServer()
        } catch {
            mutableState.withLock { $0.state = .idle }
            throw error
        }
    }

    /// Stops the node and closes all connections.
    public func stop() async {
        let (server, acceptTask, routes, wasAdvertising) = mutableState.withLock { state -> (
            GRPCServer?,
            Task<Void, Never>?,
            [String: any DistributedTransport],
            Bool
        ) in
            guard state.state == .running else {
                return (nil, nil, [:], false)
            }
            state.state = .stopping

            let result = (state.server, state.acceptTask, state.routes, state.isAdvertising)
            state.server = nil
            state.acceptTask = nil
            state.routes = [:]
            state.peerIDs = [:]
            state.isAdvertising = false
            state.state = .stopped

            return result
        }

        // Stop advertising if active
        if wasAdvertising {
            try? await discovery.stopAdvertising()
        }

        // Cancel accept task
        acceptTask?.cancel()

        // Stop all transports
        for (_, transport) in routes {
            await transport.stop()
        }

        // Stop server
        await server?.stop()

        // Finish incoming stream
        incomingContinuation.finish()
    }

    // MARK: - Connection Management

    /// Connects to a remote peer.
    ///
    /// - Parameter peer: The peer to connect to.
    /// - Throws: `PeerNodeError.notStarted` if the node hasn't been started,
    ///           `PeerNodeError.connectionFailed` if connection fails.
    public func connect(to peer: PeerID) async throws {
        let isRunning = mutableState.withLock { $0.state == .running }
        guard isRunning else {
            throw PeerNodeError.notStarted
        }

        // Check if already connected (use address as key for routing)
        let alreadyConnected = mutableState.withLock { $0.routes[peer.address] != nil }
        if alreadyConnected {
            return // Already connected
        }

        // Create transport based on type
        let transport: any DistributedTransport
        switch self.transport {
        case .grpc:
            let config = GRPCTransport.Configuration.connect(
                host: peer.host,
                port: peer.port,
                peerID: localPeerID.value
            )
            transport = GRPCTransport(configuration: config)
        }

        do {
            try await transport.start()
        } catch {
            throw PeerNodeError.connectionFailed(peer: peer, reason: error.localizedDescription)
        }

        // Store route (use address as key for routing)
        mutableState.withLock { state in
            state.routes[peer.address] = transport
            state.peerIDs[peer.address] = peer
        }
        // Note: Message handling and disconnection detection is done by the application layer
    }

    /// Disconnects from a peer.
    ///
    /// - Parameter peer: The peer to disconnect from.
    public func disconnect(from peer: PeerID) async {
        let transport = mutableState.withLock { state -> (any DistributedTransport)? in
            state.peerIDs.removeValue(forKey: peer.address)
            return state.routes.removeValue(forKey: peer.address)
        }
        guard let transport else { return }
        await transport.stop()
    }

    /// Returns the transport for communicating with a specific peer.
    ///
    /// - Parameter peer: The peer to get the transport for.
    /// - Returns: The transport if connected, nil otherwise.
    public func transport(for peer: PeerID) -> (any DistributedTransport)? {
        mutableState.withLock { $0.routes[peer.address] }
    }

    // MARK: - Discovery

    /// Whether the node is currently advertising on the local network.
    public var isAdvertising: Bool {
        mutableState.withLock { $0.isAdvertising }
    }

    /// Advertises this node on the local network using mDNS/Bonjour.
    ///
    /// Other nodes can discover this node using `discover(timeout:)`.
    /// Advertising will continue until `stopAdvertising()` is called or the node stops.
    ///
    /// - Parameter metadata: Optional metadata to include in the advertisement.
    /// - Throws: `PeerNodeError.notStarted` if the node hasn't been started,
    ///           `PeerNodeError.advertisingFailed` if advertising fails.
    public func advertise(metadata: [String: String] = [:]) async throws {
        let (isRunning, port) = mutableState.withLock { state -> (Bool, Int?) in
            (state.state == .running, state.server?.boundPort)
        }

        guard isRunning, let boundPort = port else {
            throw PeerNodeError.notStarted
        }

        let alreadyAdvertising = mutableState.withLock { $0.isAdvertising }
        if alreadyAdvertising {
            return // Already advertising
        }

        let info = ServiceInfo(name: name, port: boundPort, metadata: metadata)
        do {
            try await discovery.advertise(info: info)
            mutableState.withLock { $0.isAdvertising = true }
        } catch {
            throw PeerNodeError.advertisingFailed(error.localizedDescription)
        }
    }

    /// Stops advertising this node on the local network.
    public func stopAdvertising() async {
        mutableState.withLock { $0.isAdvertising = false }
        try? await discovery.stopAdvertising()
    }

    /// Discovers peers on the local network using mDNS/Bonjour.
    ///
    /// Returns a stream of discovered peers. The stream will complete after
    /// the timeout duration, or can be cancelled early.
    ///
    /// - Parameter timeout: Maximum time to wait for discoveries.
    /// - Returns: An async stream of discovered peers.
    public func discover(timeout: Duration) async -> AsyncThrowingStream<DiscoveredPeer, Error> {
        await discovery.discover(timeout: timeout)
    }

    /// Stream of discovery events (peer appeared, disappeared, errors).
    public var discoveryEvents: AsyncStream<DiscoveryEvent> {
        get async {
            await discovery.events
        }
    }

    // MARK: - Private

    private func startServer() async throws {
        switch transport {
        case .grpc:
            let config = GRPCServer.Configuration.listen(host: host, port: requestedPort)
            let server = GRPCServer(configuration: config)

            do {
                try await server.start()
            } catch {
                // Check if it's a port binding error
                let errorString = String(describing: error).lowercased()
                if errorString.contains("address already in use") ||
                   errorString.contains("bind") ||
                   errorString.contains("posix") ||
                   errorString.contains("serverisstopped") ||
                   errorString.contains("no listening address") {
                    // Assume port conflict for any server binding error
                    throw PeerNodeError.portUnavailable(port: requestedPort)
                }
                throw PeerNodeError.startFailed(error.localizedDescription)
            }

            // Store server and start accepting
            let acceptTask: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.acceptConnections(from: server)
            }

            mutableState.withLock { state in
                state.server = server
                state.acceptTask = acceptTask
                state.state = .running
            }
        }
    }

    private func acceptConnections(from server: GRPCServer) async {
        do {
            for try await connection in server.connections {
                // Parse peer ID from connection ID
                guard let peerID = PeerID(connection.connectionID) else {
                    continue
                }

                // Store the route (use address as key for routing)
                mutableState.withLock { state in
                    state.routes[peerID.address] = connection
                    state.peerIDs[peerID.address] = peerID
                }

                // Notify about incoming connection
                let incoming = IncomingConnection(peerID: peerID, transport: connection)
                incomingContinuation.yield(incoming)
            }
        } catch {
            // Server connection error
        }
    }

    private func removeRoute(for peer: PeerID) {
        mutableState.withLock { state in
            _ = state.routes.removeValue(forKey: peer.value)
        }
    }
}
