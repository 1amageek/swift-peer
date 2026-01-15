import Foundation
import Peer
import Synchronization
import NIOCore
import NIOPosix
import NIOFoundationCompat

// MARK: - UnixSocketTransport

/// A transport implementation using Unix domain sockets for local IPC.
/// Uses SwiftNIO for efficient async I/O.
public final class UnixSocketTransport: DistributedTransport, Sendable {

    // MARK: - Types

    public enum Mode: Sendable {
        case server
        case client
    }

    // MARK: - Private State

    private struct TransportState: ~Copyable {
        var serverChannel: (any Channel)?
        var clientChannels: [ObjectIdentifier: any Channel] = [:]
        var clientChannel: (any Channel)?
        var isStopped: Bool = false
    }

    private let mode: Mode
    private let path: String
    private let group: MultiThreadedEventLoopGroup
    private let state: Mutex<TransportState>
    private let messageStream: AsyncThrowingStream<Envelope, Error>
    private let messageContinuation: AsyncThrowingStream<Envelope, Error>.Continuation

    // MARK: - Public Properties

    public var socketPath: String { path }
    public var isServer: Bool { mode == .server }

    public var clientCount: Int {
        state.withLock { $0.clientChannels.count }
    }

    // MARK: - DistributedTransport

    public var messages: AsyncThrowingStream<Envelope, Error> {
        messageStream
    }

    // MARK: - Initialization

    public init(mode: Mode, path: String) {
        self.mode = mode
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
        switch mode {
        case .server:
            try await startServer()
        case .client:
            try await startClient()
        }
    }

    public func stop() async {
        let (serverChannel, clientChannels, clientChannel) = state.withLock { s -> ((any Channel)?, [any Channel], (any Channel)?) in
            guard !s.isStopped else { return (nil, [], nil) }
            s.isStopped = true
            let result = (s.serverChannel, Array(s.clientChannels.values), s.clientChannel)
            s.serverChannel = nil
            s.clientChannels = [:]
            s.clientChannel = nil
            return result
        }

        // Close all channels
        for channel in clientChannels {
            try? await channel.close()
        }
        if let clientChannel {
            try? await clientChannel.close()
        }
        if let serverChannel {
            try? await serverChannel.close()
        }

        // Cleanup socket file for server
        if mode == .server {
            try? FileManager.default.removeItem(atPath: path)
        }

        messageContinuation.finish()
    }

    // MARK: - Send

    public func send(_ envelope: Envelope) async throws {
        let channel: (any Channel)? = state.withLock { s in
            if mode == .server {
                return s.clientChannels.values.first
            } else {
                return s.clientChannel
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

    // MARK: - Private: Server

    private func startServer() async throws {
        let continuation = messageContinuation

        let onClientConnected: @Sendable (any Channel) -> Void = { [weak self] channel in
            self?.state.withLock { $0.clientChannels[ObjectIdentifier(channel)] = channel }
        }
        let onClientDisconnected: @Sendable (any Channel) -> Void = { [weak self] channel in
            self?.state.withLock { _ = $0.clientChannels.removeValue(forKey: ObjectIdentifier(channel)) }
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = EnvelopeChannelHandler(
                        continuation: continuation,
                        onActive: { onClientConnected(channel) },
                        onInactive: { onClientDisconnected(channel) }
                    )
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(LengthPrefixedMessageDecoder()),
                        handler
                    ])
                }
            }

        let channel = try await bootstrap.bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true).get()
        state.withLock { $0.serverChannel = channel }
    }

    // MARK: - Private: Client

    private func startClient() async throws {
        let continuation = messageContinuation

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = EnvelopeChannelHandler(continuation: continuation)
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(LengthPrefixedMessageDecoder()),
                        handler
                    ])
                }
            }

        let channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
        state.withLock { $0.clientChannel = channel }
    }
}

// MARK: - LengthPrefixedMessageDecoder

/// Decodes length-prefixed messages (4-byte UInt32 length + payload).
private final class LengthPrefixedMessageDecoder: ByteToMessageDecoder, Sendable {
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

// MARK: - EnvelopeChannelHandler

/// Handles incoming ByteBuffers, decodes them as Envelope, and yields to continuation.
private final class EnvelopeChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncThrowingStream<Envelope, Error>.Continuation
    private let onActive: (@Sendable () -> Void)?
    private let onInactive: (@Sendable () -> Void)?

    init(
        continuation: AsyncThrowingStream<Envelope, Error>.Continuation,
        onActive: (@Sendable () -> Void)? = nil,
        onInactive: (@Sendable () -> Void)? = nil
    ) {
        self.continuation = continuation
        self.onActive = onActive
        self.onInactive = onInactive
    }

    func channelActive(context: ChannelHandlerContext) {
        onActive?()
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        onInactive?()
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
            // Silently ignore decode errors for now
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}

// MARK: - Errors

public enum UnixSocketError: Error, Sendable {
    case socketCreationFailed
    case bindFailed
    case listenFailed
    case connectionFailed
    case notConnected
    case noClients
    case sendFailed
}
