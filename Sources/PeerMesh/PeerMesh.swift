import Foundation
import Peer
import Synchronization

/// A router that directs messages to the appropriate transport based on recipient.
///
/// `PeerMesh` maintains a routing table mapping peer identifiers to transports,
/// enabling targeted message delivery rather than broadcasting.
///
/// ## Features
///
/// - **Routing**: Directs messages to specific transports based on recipientID
/// - **Multi-transport**: Manages connections to multiple peers via different transports
/// - **Unified stream**: Merges incoming messages from all transports
///
/// ## Usage
///
/// ```swift
/// let mesh = PeerMesh()
///
/// // Register routes
/// mesh.addRoute(to: "bob", via: bobTransport)
/// mesh.addRoute(to: "charlie", via: charlieTransport)
///
/// // Send to specific peer (routed by recipientID)
/// try await mesh.send(.invocation(envelope))  // routes to "bob" if recipientID == "bob"
///
/// // Receive from all peers
/// for try await message in mesh.messages {
///     // Handle message
/// }
/// ```
public final class PeerMesh: DistributedTransport, Sendable {

    // MARK: - Mutable State

    private struct MutableState: ~Copyable {
        /// Routing table: peerID -> Transport
        var routes: [String: any DistributedTransport] = [:]
        /// Reverse lookup: track which transport a message came from (for responses)
        var callIDToSender: [String: String] = [:]
        /// Forwarding tasks for each transport
        var forwardingTasks: [String: Task<Void, Never>] = [:]
        var isStarted: Bool = false
        var isStopped: Bool = false
    }

    // MARK: - Properties

    private let mutableState: Mutex<MutableState>
    private let messageStream: AsyncThrowingStream<Envelope, Error>
    private let messageContinuation: AsyncThrowingStream<Envelope, Error>.Continuation

    /// All registered peer IDs
    public var peers: [String] {
        mutableState.withLock { Array($0.routes.keys) }
    }

    // MARK: - DistributedTransport

    public var messages: AsyncThrowingStream<Envelope, Error> {
        messageStream
    }

    // MARK: - Initialization

    public init() {
        self.mutableState = Mutex(MutableState())

        var continuation: AsyncThrowingStream<Envelope, Error>.Continuation!
        self.messageStream = AsyncThrowingStream { cont in
            continuation = cont
        }
        self.messageContinuation = continuation
    }

    // MARK: - Route Management

    /// Add a route to a peer
    ///
    /// - Parameters:
    ///   - peerID: The identifier of the peer
    ///   - transport: The transport to use for reaching this peer
    public func addRoute(to peerID: String, via transport: any DistributedTransport) {
        mutableState.withLock { state in
            guard !state.isStopped else { return }
            state.routes[peerID] = transport
        }

        startForwarding(from: transport, peerID: peerID)
    }

    /// Remove a route to a peer
    ///
    /// - Parameter peerID: The identifier of the peer to remove
    /// - Returns: The removed transport, if any
    @discardableResult
    public func removeRoute(to peerID: String) -> (any DistributedTransport)? {
        let (transport, task) = mutableState.withLock { state -> ((any DistributedTransport)?, Task<Void, Never>?) in
            let transport = state.routes.removeValue(forKey: peerID)
            let task = state.forwardingTasks.removeValue(forKey: peerID)
            return (transport, task)
        }

        task?.cancel()
        return transport
    }

    /// Check if a route exists to a peer
    public func hasRoute(to peerID: String) -> Bool {
        mutableState.withLock { $0.routes[peerID] != nil }
    }

    // MARK: - DistributedTransport: start

    public func start() async throws {
        let shouldThrow = mutableState.withLock { state -> Bool in
            if state.isStopped {
                return true
            }
            state.isStarted = true
            return false
        }

        if shouldThrow {
            throw PeerMeshError.alreadyStopped
        }
    }

    // MARK: - DistributedTransport: send

    public func send(_ envelope: Envelope) async throws {
        let recipientID = try extractRecipientID(from: envelope)

        let transport = mutableState.withLock { state -> (any DistributedTransport)? in
            state.routes[recipientID]
        }

        guard let transport else {
            throw PeerMeshError.noRoute(to: recipientID)
        }

        try await transport.send(envelope)
    }

    // MARK: - DistributedTransport: stop

    public func stop() async {
        let (transports, tasks) = mutableState.withLock { state -> (
            [any DistributedTransport],
            [Task<Void, Never>]
        ) in
            guard !state.isStopped else { return ([], []) }
            state.isStopped = true

            let transports = Array(state.routes.values)
            let tasks = Array(state.forwardingTasks.values)

            state.routes = [:]
            state.forwardingTasks = [:]
            state.callIDToSender = [:]

            return (transports, tasks)
        }

        for task in tasks {
            task.cancel()
        }

        for transport in transports {
            await transport.stop()
        }

        messageContinuation.finish()
    }

    // MARK: - Private

    private func extractRecipientID(from envelope: Envelope) throws -> String {
        switch envelope {
        case .invocation(let inv):
            return inv.recipientID

        case .response(let res):
            // For responses, look up the original sender from callID
            let senderID = mutableState.withLock { state in
                state.callIDToSender[res.callID]
            }
            guard let senderID else {
                throw PeerMeshError.unknownCallID(res.callID)
            }
            return senderID
        }
    }

    private func startForwarding(from transport: any DistributedTransport, peerID: String) {
        let task = Task { [weak self] in
            guard let self else { return }

            do {
                for try await envelope in transport.messages {
                    // Track sender for response routing
                    if case .invocation(let inv) = envelope, let senderID = inv.senderID {
                        self.mutableState.withLock { state in
                            state.callIDToSender[inv.callID] = senderID
                        }
                    }

                    self.messageContinuation.yield(envelope)
                }
            } catch {
                // Transport closed
            }

            // Transport disconnected
            self.mutableState.withLock { state in
                state.routes.removeValue(forKey: peerID)
                state.forwardingTasks.removeValue(forKey: peerID)
            }
        }

        mutableState.withLock { state in
            state.forwardingTasks[peerID] = task
        }
    }
}

// MARK: - Errors

public enum PeerMeshError: Error, Sendable {
    case alreadyStopped
    case noRoute(to: String)
    case unknownCallID(String)
}
