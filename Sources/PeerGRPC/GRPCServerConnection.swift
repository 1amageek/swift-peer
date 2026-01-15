import Foundation
import Peer
import GRPCCore
import Synchronization

/// Represents a single client connection from the server's perspective.
///
/// `GRPCServerConnection` is created by `GRPCServer` for each connected client.
/// It implements `DistributedTransport` to provide a 1:1 communication channel
/// with that specific client.
///
/// ## Lifecycle
///
/// 1. Created when a client connects via bidirectional streaming
/// 2. Messages flow bidirectionally through `send()` and `messages`
/// 3. When the gRPC stream ends (client disconnects), connection is closed
/// 4. After closing, `send()` throws `GRPCConnectionError.connectionClosed`
///
/// ## Thread Safety
///
/// This class is `Sendable` and safe to use from multiple tasks concurrently.
/// Internal state is protected by a `Mutex`.
///
public final class GRPCServerConnection: DistributedTransport, Sendable {

    // MARK: - Types

    private enum ConnectionState: Sendable {
        case connected
        case closing
        case closed
    }

    private struct MutableState: ~Copyable {
        var outgoingContinuation: AsyncStream<EnvelopeMessage>.Continuation?
        var connectionState: ConnectionState = .connected
    }

    // MARK: - Properties

    /// Unique identifier for this connection.
    ///
    /// This is derived from client metadata (e.g., `x-peer-id` header) or
    /// auto-generated as a UUID if no identifier is provided.
    public let connectionID: String

    private let mutableState: Mutex<MutableState>
    private let messageStream: AsyncThrowingStream<Envelope, Error>
    private let messageContinuation: AsyncThrowingStream<Envelope, Error>.Continuation
    private let onClose: @Sendable () -> Void

    // MARK: - DistributedTransport

    public var messages: AsyncThrowingStream<Envelope, Error> {
        messageStream
    }

    // MARK: - Initialization

    /// Creates a new server connection.
    ///
    /// - Parameters:
    ///   - connectionID: Unique identifier for this connection.
    ///   - outgoingContinuation: Continuation for sending messages to the client.
    ///   - onClose: Callback invoked when the connection closes.
    init(
        connectionID: String,
        outgoingContinuation: AsyncStream<EnvelopeMessage>.Continuation,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.connectionID = connectionID
        self.onClose = onClose

        var state = MutableState()
        state.outgoingContinuation = outgoingContinuation
        self.mutableState = Mutex(state)

        var continuation: AsyncThrowingStream<Envelope, Error>.Continuation!
        self.messageStream = AsyncThrowingStream { cont in
            continuation = cont
        }
        self.messageContinuation = continuation
    }

    // MARK: - DistributedTransport: start

    /// No-op for server connections (already started when created).
    public func start() async throws {
        // Server connections are already started when created
    }

    // MARK: - DistributedTransport: send

    public func send(_ envelope: Envelope) async throws {
        let continuation = mutableState.withLock { state -> AsyncStream<EnvelopeMessage>.Continuation? in
            switch state.connectionState {
            case .connected:
                return state.outgoingContinuation
            case .closing, .closed:
                return nil
            }
        }

        guard let continuation else {
            throw GRPCConnectionError.connectionClosed
        }

        continuation.yield(EnvelopeMessage(envelope: envelope))
    }

    // MARK: - DistributedTransport: stop

    public func stop() async {
        close(reason: .graceful)
    }

    // MARK: - Internal: Message Handling

    /// Yields an incoming message from the client.
    ///
    /// Called by `GRPCServerService` when a message arrives on the stream.
    func yieldIncoming(_ envelope: Envelope) {
        let isClosed = mutableState.withLock { $0.connectionState != .connected }
        if !isClosed {
            messageContinuation.yield(envelope)
        }
    }

    /// Handles an error on the stream.
    ///
    /// Called by `GRPCServerService` when an error occurs.
    func handleError(_ error: Error) {
        close(reason: .error(error))
    }

    /// Called when the underlying gRPC stream ends.
    ///
    /// This invalidates the outgoing continuation and finishes the message stream.
    func handleStreamEnded() {
        close(reason: .streamEnded)
    }

    // MARK: - Private

    private enum CloseReason {
        case graceful
        case streamEnded
        case error(Error)
    }

    private func close(reason: CloseReason) {
        let (shouldNotify, continuation) = mutableState.withLock { state -> (Bool, AsyncStream<EnvelopeMessage>.Continuation?) in
            guard state.connectionState == .connected else {
                return (false, nil)
            }

            state.connectionState = .closing
            let cont = state.outgoingContinuation
            state.outgoingContinuation = nil
            state.connectionState = .closed

            return (true, cont)
        }

        if shouldNotify {
            continuation?.finish()

            switch reason {
            case .graceful, .streamEnded:
                messageContinuation.finish()
            case .error(let error):
                messageContinuation.finish(throwing: error)
            }

            onClose()
        }
    }
}

// MARK: - Errors

/// Errors specific to gRPC server connections.
public enum GRPCConnectionError: Error, Sendable {
    /// The connection has been closed.
    case connectionClosed

    /// Failed to send a message.
    case sendFailed(String)
}
