import Foundation
import Peer
import Synchronization
import NIOCore
import NIOPosix
import NIOFoundationCompat

// MARK: - UnixSocketTransport

/// A Unix socket client transport for connecting to a server.
///
/// `UnixSocketTransport` represents a single client connection to a Unix socket server.
/// For accepting multiple client connections, use `UnixSocketServer` instead.
///
/// ## Usage
///
/// ```swift
/// let transport = UnixSocketTransport(path: "/tmp/myapp.sock")
/// try await transport.start()
///
/// // Send messages
/// try await transport.send(.invocation(envelope))
///
/// // Receive messages
/// for try await envelope in transport.messages {
///     // Handle message
/// }
///
/// // Cleanup
/// await transport.stop()
/// ```
///
public final class UnixSocketTransport: DistributedTransport, @unchecked Sendable {

    // MARK: - Types

    private enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case closing
        case closed
    }

    // MARK: - Private State

    private struct TransportState: ~Copyable {
        var channel: (any Channel)?
        var connectionState: ConnectionState = .disconnected
    }

    private let path: String
    private let group: MultiThreadedEventLoopGroup
    private let state: Mutex<TransportState>
    private let messageStream: AsyncThrowingStream<Envelope, Error>
    private let messageContinuation: AsyncThrowingStream<Envelope, Error>.Continuation

    // MARK: - Public Properties

    /// The socket path to connect to.
    public var socketPath: String { path }

    // MARK: - DistributedTransport

    public var messages: AsyncThrowingStream<Envelope, Error> {
        messageStream
    }

    // MARK: - Initialization

    /// Creates a new Unix socket client transport.
    ///
    /// - Parameter path: The path to the Unix socket to connect to.
    public init(path: String) {
        self.path = path
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.state = Mutex(TransportState())

        var continuation: AsyncThrowingStream<Envelope, Error>.Continuation!
        self.messageStream = AsyncThrowingStream { cont in
            continuation = cont
        }
        self.messageContinuation = continuation
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    // MARK: - Lifecycle

    public func start() async throws {
        let currentState = state.withLock { s -> ConnectionState in
            let current = s.connectionState
            if current == .disconnected {
                s.connectionState = .connecting
            }
            return current
        }

        switch currentState {
        case .disconnected:
            break // proceed
        case .connecting, .connected:
            throw UnixSocketError.alreadyConnected
        case .closing, .closed:
            throw UnixSocketError.alreadyClosed
        }

        do {
            try await connect()
        } catch {
            // Only reset to disconnected if we're still in connecting state.
            // If stop() was called during connect(), state is now closed
            // and we should NOT reset it to disconnected (which would allow restart).
            state.withLock { s in
                if s.connectionState == .connecting {
                    s.connectionState = .disconnected
                }
            }
            throw error
        }
    }

    public func stop() async {
        let channel = state.withLock { s -> (any Channel)? in
            guard s.connectionState != .closing && s.connectionState != .closed else {
                return nil
            }
            s.connectionState = .closing
            let chan = s.channel
            s.channel = nil
            s.connectionState = .closed
            return chan
        }

        if let channel {
            try? await channel.close()
        }

        messageContinuation.finish()
    }

    // MARK: - Send

    public func send(_ envelope: Envelope) async throws {
        let channel = state.withLock { s -> (any Channel)? in
            switch s.connectionState {
            case .connected:
                return s.channel
            case .disconnected, .connecting, .closing, .closed:
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

    // MARK: - Private: Connection

    private func connect() async throws {
        let continuation = messageContinuation

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = ClientChannelHandler(
                        continuation: continuation,
                        onInactive: { [weak self] in
                            self?.handleChannelInactive()
                        }
                    )
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(ClientLengthPrefixedDecoder()),
                        handler
                    ])
                }
            }

        let channel = try await bootstrap.connect(unixDomainSocketPath: path).get()

        // Atomically check state and set resources
        // If stop() was called during async operations above, don't proceed
        let shouldProceed = state.withLock { s -> Bool in
            guard s.connectionState == .connecting else {
                return false  // stop() was called, don't proceed
            }
            s.channel = channel
            s.connectionState = .connected
            return true
        }

        if !shouldProceed {
            // Cancelled - clean up the channel we just created
            try? await channel.close()
            throw UnixSocketError.alreadyClosed
        }
    }

    private func handleChannelInactive() {
        let shouldFinish = state.withLock { s -> Bool in
            guard s.connectionState == .connected else { return false }
            s.connectionState = .closed
            s.channel = nil
            return true
        }

        if shouldFinish {
            messageContinuation.finish()
        }
    }
}

// MARK: - Client Length-Prefixed Decoder

/// Decodes length-prefixed messages (4-byte UInt32 length + payload).
private final class ClientLengthPrefixedDecoder: ByteToMessageDecoder, Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let messageSlice = buffer.readLengthPrefixedSlice(as: UInt32.self) else {
            return .needMoreData
        }
        context.fireChannelRead(Self.wrapInboundOut(messageSlice))
        return .continue
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        while let messageSlice = buffer.readLengthPrefixedSlice(as: UInt32.self) {
            context.fireChannelRead(Self.wrapInboundOut(messageSlice))
        }
        return .needMoreData
    }
}

// MARK: - Client Channel Handler

/// Handles incoming ByteBuffers, decodes them as Envelope, and yields to continuation.
private final class ClientChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncThrowingStream<Envelope, Error>.Continuation
    private let onInactive: @Sendable () -> Void

    init(
        continuation: AsyncThrowingStream<Envelope, Error>.Continuation,
        onInactive: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.onInactive = onInactive
    }

    func channelInactive(context: ChannelHandlerContext) {
        onInactive()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let data = buffer.readData(length: buffer.readableBytes) else {
            return
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            continuation.yield(envelope)
        } catch {
            // Report decode error and close the channel
            // This ensures consistent state: stream finished = channel closed
            continuation.finish(throwing: UnixSocketError.decodeError(error))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}

// MARK: - Errors

/// Errors that can occur in Unix socket operations.
public enum UnixSocketError: Error, Sendable {
    /// Failed to create the socket.
    case socketCreationFailed

    /// Failed to bind to the socket path.
    case bindFailed

    /// Failed to listen on the socket.
    case listenFailed

    /// Failed to connect to the server.
    case connectionFailed

    /// Not connected to the server.
    case notConnected

    /// Already connected to the server.
    case alreadyConnected

    /// The transport has been closed.
    case alreadyClosed

    /// No clients connected (server mode).
    case noClients

    /// Failed to send data.
    case sendFailed

    /// Failed to decode received data.
    case decodeError(Error)

    /// The server is already running.
    case alreadyRunning

    /// The server has been stopped.
    case serverStopped
}
