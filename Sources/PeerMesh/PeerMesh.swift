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
/// - **Response tracking**: Automatically routes responses back to the original sender
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
///
/// ## Response Routing
///
/// When an invocation arrives, PeerMesh tracks the sender so responses can be
/// routed back correctly. The sender is determined by:
/// 1. `InvocationEnvelope.senderID` if present
/// 2. The peer ID associated with the transport that delivered the message
///
/// This means responses will work even if the original invocation didn't include
/// a `senderID`.
///
public final class PeerMesh: DistributedTransport, Sendable {

    // MARK: - Types

    /// Tracks a pending call for response routing.
    private struct PendingCall: Sendable {
        /// The peer ID to route the response to.
        let senderPeerID: String
        /// When the call was received.
        let timestamp: Date
    }

    // MARK: - Mutable State

    private struct MutableState: ~Copyable {
        /// Routing table: peerID -> Transport
        var routes: [String: any DistributedTransport] = [:]

        /// Pending call tracking: callID -> PendingCall
        /// Used to route responses back to the original sender.
        var pendingCalls: [String: PendingCall] = [:]

        /// Forwarding tasks for each transport
        var forwardingTasks: [String: Task<Void, Never>] = [:]

        var isStarted: Bool = false
        var isStopped: Bool = false
    }

    // MARK: - Properties

    private let mutableState: Mutex<MutableState>
    private let messageStream: AsyncThrowingStream<Envelope, Error>
    private let messageContinuation: AsyncThrowingStream<Envelope, Error>.Continuation

    /// All registered peer IDs.
    public var peers: [String] {
        mutableState.withLock { Array($0.routes.keys) }
    }

    /// Number of pending calls awaiting responses.
    public var pendingCallCount: Int {
        mutableState.withLock { $0.pendingCalls.count }
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

    /// Add a route to a peer.
    ///
    /// - Parameters:
    ///   - peerID: The identifier of the peer.
    ///   - transport: The transport to use for reaching this peer.
    public func addRoute(to peerID: String, via transport: any DistributedTransport) {
        mutableState.withLock { state in
            guard !state.isStopped else { return }
            state.routes[peerID] = transport
        }

        startForwarding(from: transport, peerID: peerID)
    }

    /// Remove a route to a peer.
    ///
    /// - Parameter peerID: The identifier of the peer to remove.
    /// - Returns: The removed transport, if any.
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

    /// Check if a route exists to a peer.
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
        switch envelope {
        case .invocation(let inv):
            try await sendInvocation(inv)

        case .response(let res):
            try await sendResponse(res)
        }
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
            state.pendingCalls = [:]

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

    // MARK: - Cleanup

    /// Remove stale pending calls older than the specified duration.
    ///
    /// Call this periodically to prevent memory leaks from orphaned calls
    /// (e.g., when a response never arrives due to network issues).
    ///
    /// - Parameter duration: Maximum age for pending calls. Default is 5 minutes.
    /// - Returns: Number of calls that were cleaned up.
    @discardableResult
    public func cleanupStaleCalls(olderThan duration: TimeInterval = 300) -> Int {
        let cutoff = Date().addingTimeInterval(-duration)
        return mutableState.withLock { state in
            let before = state.pendingCalls.count
            state.pendingCalls = state.pendingCalls.filter { _, call in
                call.timestamp > cutoff
            }
            return before - state.pendingCalls.count
        }
    }

    // MARK: - Private: Send

    private func sendInvocation(_ inv: InvocationEnvelope) async throws {
        let transport = mutableState.withLock { state -> (any DistributedTransport)? in
            state.routes[inv.recipientID]
        }

        guard let transport else {
            throw PeerMeshError.noRoute(to: inv.recipientID)
        }

        try await transport.send(.invocation(inv))
    }

    private func sendResponse(_ res: ResponseEnvelope) async throws {
        // Look up and remove the pending call in one atomic operation
        let (transport, _) = mutableState.withLock { state -> ((any DistributedTransport)?, PendingCall?) in
            guard let pending = state.pendingCalls.removeValue(forKey: res.callID) else {
                return (nil, nil)
            }
            return (state.routes[pending.senderPeerID], pending)
        }

        guard let transport else {
            throw PeerMeshError.unknownCallID(res.callID)
        }

        try await transport.send(.response(res))
    }

    // MARK: - Private: Forwarding

    private func startForwarding(from transport: any DistributedTransport, peerID: String) {
        let task = Task { [weak self] in
            guard let self else { return }

            do {
                for try await envelope in transport.messages {
                    switch envelope {
                    case .invocation(let inv):
                        // Track the sender for response routing.
                        // SECURITY: Always use the transport-layer peerID, not the
                        // application-layer senderID. This prevents spoofing attacks
                        // where a malicious peer could redirect responses to other peers.
                        let trustedSenderID = peerID

                        // Log mismatch for debugging/monitoring (senderID != peerID could
                        // indicate a spoofing attempt or misconfiguration)
                        #if DEBUG
                        if let claimedSenderID = inv.senderID, claimedSenderID != peerID {
                            // In production, this should go to a proper logging framework
                            print("[PeerMesh] Warning: senderID mismatch - claimed: \(claimedSenderID), transport: \(peerID)")
                        }
                        #endif

                        self.mutableState.withLock { state in
                            state.pendingCalls[inv.callID] = PendingCall(
                                senderPeerID: trustedSenderID,
                                timestamp: Date()
                            )
                        }
                        self.messageContinuation.yield(.invocation(inv))

                    case .response(let res):
                        // Responses pass through directly.
                        // They will be matched by callID on the receiving end.
                        self.messageContinuation.yield(.response(res))
                    }
                }
            } catch {
                self.handleTransportError(peerID: peerID, error: error)
            }

            // Transport disconnected
            self.handleTransportDisconnected(peerID: peerID)
        }

        mutableState.withLock { state in
            state.forwardingTasks[peerID] = task
        }
    }

    private func handleTransportError(peerID: String, error: Error) {
        // The transport encountered an error.
        // We could emit an event here if needed.
    }

    private func handleTransportDisconnected(peerID: String) {
        mutableState.withLock { state in
            state.routes.removeValue(forKey: peerID)
            state.forwardingTasks.removeValue(forKey: peerID)
        }
    }
}

// MARK: - Errors

/// Errors specific to PeerMesh operations.
public enum PeerMeshError: Error, Sendable {
    /// The mesh has been stopped and cannot be used.
    case alreadyStopped

    /// No route exists to the specified peer.
    case noRoute(to: String)

    /// The call ID is not recognized (response to unknown invocation).
    case unknownCallID(String)
}
