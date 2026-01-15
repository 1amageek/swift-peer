import Foundation
import Peer
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

/// A gRPC server that accepts connections and creates transports for each.
///
/// `GRPCServer` implements `TransportServer` to provide a pattern where each
/// client connection becomes a separate `GRPCServerConnection` instance.
/// This ensures proper 1:1 connection semantics.
///
/// ## Usage
///
/// ```swift
/// let server = GRPCServer(configuration: .listen(port: 50051))
/// try await server.start()
///
/// print("Server listening on: \(await server.boundAddress ?? "unknown")")
///
/// // Handle each connection
/// for try await connection in server.connections {
///     print("Client connected: \(connection.connectionID)")
///
///     Task {
///         for try await envelope in connection.messages {
///             // Handle message from this specific client
///             switch envelope {
///             case .invocation(let inv):
///                 // Process invocation
///                 let response = ResponseEnvelope(
///                     callID: inv.callID,
///                     result: .void
///                 )
///                 try await connection.send(.response(response))
///             case .response(let res):
///                 // Handle response
///                 break
///             }
///         }
///         print("Client disconnected: \(connection.connectionID)")
///     }
/// }
///
/// // Cleanup
/// await server.stop()
/// ```
///
public final class GRPCServer: TransportServer, Sendable {

    // MARK: - Type Aliases

    private typealias ServerTransportType = HTTP2ServerTransport.Posix

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let host: String
        public let port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }

        /// Create a server configuration for listening on the specified port.
        ///
        /// - Parameters:
        ///   - host: The host address to bind to. Defaults to "0.0.0.0" (all interfaces).
        ///   - port: The port to listen on. Use 0 to let the system assign a port.
        /// - Returns: A server configuration.
        public static func listen(host: String = "0.0.0.0", port: Int = 50051) -> Configuration {
            Configuration(host: host, port: port)
        }
    }

    // MARK: - Mutable State

    private struct MutableState: ~Copyable {
        var server: GRPCCore.GRPCServer<ServerTransportType>?
        var serverTask: Task<Void, Error>?
        var boundPort: Int?
        var isStopped: Bool = false
    }

    // MARK: - Properties

    private let configuration: Configuration
    private let mutableState: Mutex<MutableState>
    private let connectionStream: AsyncThrowingStream<GRPCServerConnection, Error>
    private let connectionContinuation: AsyncThrowingStream<GRPCServerConnection, Error>.Continuation

    // MARK: - TransportServer

    public typealias Connection = GRPCServerConnection

    public var connections: AsyncThrowingStream<GRPCServerConnection, Error> {
        connectionStream
    }

    public var boundAddress: String? {
        get async {
            guard let port = mutableState.withLock({ $0.boundPort }) else {
                return nil
            }
            return "\(configuration.host):\(port)"
        }
    }

    /// The port the server is bound to after starting.
    ///
    /// This is useful when port 0 is used to let the system assign a port.
    public var boundPort: Int? {
        mutableState.withLock { $0.boundPort }
    }

    // MARK: - Initialization

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.mutableState = Mutex(MutableState())

        var continuation: AsyncThrowingStream<GRPCServerConnection, Error>.Continuation!
        self.connectionStream = AsyncThrowingStream { cont in
            continuation = cont
        }
        self.connectionContinuation = continuation
    }

    // MARK: - TransportServer: start

    public func start() async throws {
        let isStopped = mutableState.withLock { $0.isStopped }
        if isStopped {
            throw GRPCServerError.alreadyStopped
        }

        let alreadyRunning = mutableState.withLock { $0.server != nil }
        if alreadyRunning {
            throw GRPCServerError.alreadyRunning
        }

        // Create service that emits connections
        let service = GRPCServerService { [connectionContinuation] connection in
            connectionContinuation.yield(connection)
        }

        // Create transport
        let transport = ServerTransportType(
            address: .ipv4(host: configuration.host, port: configuration.port),
            transportSecurity: .plaintext
        )

        // Create server
        let grpcServer = GRPCCore.GRPCServer(
            transport: transport,
            services: [service]
        )

        // Start serving
        let task = Task {
            try await grpcServer.serve()
        }

        mutableState.withLock {
            $0.server = grpcServer
            $0.serverTask = task
        }

        // Wait for server to bind and get the actual port
        guard let address = try await grpcServer.listeningAddress else {
            throw GRPCServerError.bindFailed("Failed to get listening address")
        }

        let port: Int
        if let ipv4 = address.ipv4 {
            port = ipv4.port
        } else if let ipv6 = address.ipv6 {
            port = ipv6.port
        } else {
            port = configuration.port
        }

        mutableState.withLock { $0.boundPort = port }
    }

    // MARK: - TransportServer: stop

    public func stop() async {
        let (server, task) = mutableState.withLock { state -> (GRPCCore.GRPCServer<ServerTransportType>?, Task<Void, Error>?) in
            guard !state.isStopped else { return (nil, nil) }
            state.isStopped = true

            let server = state.server
            let task = state.serverTask

            state.server = nil
            state.serverTask = nil
            state.boundPort = nil

            return (server, task)
        }

        // Shutdown server
        server?.beginGracefulShutdown()
        task?.cancel()

        // Finish connection stream
        connectionContinuation.finish()
    }
}

// MARK: - Errors

/// Errors specific to GRPCServer.
public enum GRPCServerError: Error, Sendable {
    /// The server is already running.
    case alreadyRunning

    /// The server has been stopped and cannot be restarted.
    case alreadyStopped

    /// Failed to bind to the specified address.
    case bindFailed(String)
}
