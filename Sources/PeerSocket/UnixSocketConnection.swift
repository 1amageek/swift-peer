import Foundation
import Peer
import Synchronization
import NIOCore
import NIOPosix
import NIOFoundationCompat

/// Represents a single client connection from the server's perspective.
///
/// `UnixSocketConnection` is created by `UnixSocketServer` for each connected client.
/// It implements `DistributedTransport` to provide a 1:1 communication channel
/// with that specific client.
///
/// ## Lifecycle
///
/// 1. Created when a client connects
/// 2. Messages flow bidirectionally through `send()` and `messages`
/// 3. When the client disconnects, connection is closed
/// 4. After closing, `send()` throws `UnixSocketError.notConnected`
///
public final class UnixSocketConnection: DistributedTransport, @unchecked Sendable {

    // MARK: - Types

    private enum ConnectionState: Sendable {
        case connected
        case closing
        case closed
    }

    private struct MutableState: ~Copyable {
        var channel: (any Channel)?
        var connectionState: ConnectionState = .connected
    }

    // MARK: - Properties

    /// Unique identifier for this connection.
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
    ///   - channel: The NIO channel for this connection.
    ///   - onClose: Callback invoked when the connection closes.
    init(
        connectionID: String,
        channel: any Channel,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.connectionID = connectionID
        self.onClose = onClose

        var state = MutableState()
        state.channel = channel
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
        let channel = mutableState.withLock { state -> (any Channel)? in
            switch state.connectionState {
            case .connected:
                return state.channel
            case .closing, .closed:
                return nil
            }
        }

        guard let channel else {
            throw UnixSocketError.notConnected
        }

        let data = try JSONEncoder().encode(envelope)
        var buffer = channel.allocator.buffer(capacity: 4 + data.count)
        try buffer.writeLengthPrefixed(as: UInt32.self) { buf in
            buf.writeData(data)
        }
        try await channel.writeAndFlush(buffer)
    }

    // MARK: - DistributedTransport: stop

    public func stop() async {
        await close(reason: .graceful)
    }

    // MARK: - Internal: Message Handling

    /// Yields an incoming message from the client.
    func yieldIncoming(_ envelope: Envelope) {
        let isClosed = mutableState.withLock { $0.connectionState != .connected }
        if !isClosed {
            messageContinuation.yield(envelope)
        }
    }

    /// Handles an error on the connection.
    func handleError(_ error: Error) {
        Task {
            await close(reason: .error(error))
        }
    }

    /// Called when the underlying channel becomes inactive.
    func handleChannelInactive() {
        Task {
            await close(reason: .disconnected)
        }
    }

    // MARK: - Private

    private enum CloseReason {
        case graceful
        case disconnected
        case error(Error)
    }

    private func close(reason: CloseReason) async {
        let (shouldNotify, channel) = mutableState.withLock { state -> (Bool, (any Channel)?) in
            guard state.connectionState == .connected else {
                return (false, nil)
            }

            state.connectionState = .closing
            let chan = state.channel
            state.channel = nil
            state.connectionState = .closed

            return (true, chan)
        }

        if shouldNotify {
            // Close the channel
            if let channel {
                try? await channel.close()
            }

            switch reason {
            case .graceful, .disconnected:
                messageContinuation.finish()
            case .error(let error):
                messageContinuation.finish(throwing: error)
            }

            onClose()
        }
    }
}
