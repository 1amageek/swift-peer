import Foundation
import Peer
import Synchronization
import NIOCore
import NIOPosix
import NIOFoundationCompat

/// A Unix socket server that accepts connections and creates transports for each.
///
/// `UnixSocketServer` implements `TransportServer` to provide a pattern where each
/// client connection becomes a separate `UnixSocketConnection` instance.
/// This ensures proper 1:1 connection semantics.
///
/// ## Usage
///
/// ```swift
/// let server = UnixSocketServer(path: "/tmp/myapp.sock")
/// try await server.start()
///
/// // Handle each connection
/// for try await connection in server.connections {
///     print("Client connected: \(connection.connectionID)")
///
///     Task {
///         for try await envelope in connection.messages {
///             // Handle message from this specific client
///         }
///         print("Client disconnected: \(connection.connectionID)")
///     }
/// }
///
/// // Cleanup
/// await server.stop()
/// ```
///
public final class UnixSocketServer: TransportServer, Sendable {

    // MARK: - Mutable State

    private struct MutableState: ~Copyable {
        var serverChannel: (any Channel)?
        var connections: [String: UnixSocketConnection] = [:]
        var isStopped: Bool = false
    }

    // MARK: - Properties

    private let path: String
    private let group: MultiThreadedEventLoopGroup
    private let mutableState: Mutex<MutableState>
    private let connectionStream: AsyncThrowingStream<UnixSocketConnection, Error>
    private let connectionContinuation: AsyncThrowingStream<UnixSocketConnection, Error>.Continuation

    /// The socket path.
    public var socketPath: String { path }

    // MARK: - TransportServer

    public typealias Connection = UnixSocketConnection

    public var connections: AsyncThrowingStream<UnixSocketConnection, Error> {
        connectionStream
    }

    public var boundAddress: String? {
        get async {
            let hasServer = mutableState.withLock { $0.serverChannel != nil }
            return hasServer ? path : nil
        }
    }

    // MARK: - Initialization

    public init(path: String) {
        self.path = path
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.mutableState = Mutex(MutableState())

        var continuation: AsyncThrowingStream<UnixSocketConnection, Error>.Continuation!
        self.connectionStream = AsyncThrowingStream { cont in
            continuation = cont
        }
        self.connectionContinuation = continuation
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    // MARK: - TransportServer: start

    public func start() async throws {
        let isStopped = mutableState.withLock { $0.isStopped }
        if isStopped {
            throw UnixSocketServerError.serverStopped
        }

        let alreadyRunning = mutableState.withLock { $0.serverChannel != nil }
        if alreadyRunning {
            throw UnixSocketServerError.alreadyRunning
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let self else { return }

                    let connectionID = UUID().uuidString
                    let connection = UnixSocketConnection(
                        connectionID: connectionID,
                        channel: channel,
                        onClose: { [weak self] in
                            _ = self?.mutableState.withLock { state in
                                state.connections.removeValue(forKey: connectionID)
                            }
                        }
                    )

                    self.mutableState.withLock { state in
                        state.connections[connectionID] = connection
                    }

                    let handler = ServerConnectionHandler(connection: connection)
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(LengthPrefixedMessageDecoder()),
                        handler
                    ])

                    self.connectionContinuation.yield(connection)
                }
            }

        let channel = try await bootstrap.bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true).get()
        mutableState.withLock { $0.serverChannel = channel }
    }

    // MARK: - TransportServer: stop

    public func stop() async {
        let (serverChannel, connections) = mutableState.withLock { state -> ((any Channel)?, [UnixSocketConnection]) in
            guard !state.isStopped else { return (nil, []) }
            state.isStopped = true

            let server = state.serverChannel
            let conns = Array(state.connections.values)

            state.serverChannel = nil
            state.connections = [:]

            return (server, conns)
        }

        // Close all connections
        for connection in connections {
            await connection.stop()
        }

        // Close server channel
        if let serverChannel {
            try? await serverChannel.close()
        }

        // Cleanup socket file
        try? FileManager.default.removeItem(atPath: path)

        connectionContinuation.finish()
    }
}

// MARK: - Server Connection Handler

/// Handles incoming data for a server-side connection.
private final class ServerConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let connection: UnixSocketConnection

    init(connection: UnixSocketConnection) {
        self.connection = connection
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection.handleChannelInactive()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let data = buffer.readData(length: buffer.readableBytes) else {
            return
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            connection.yieldIncoming(envelope)
        } catch {
            // Report decode error instead of silently ignoring
            connection.handleError(UnixSocketServerError.decodeError(error))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        connection.handleError(error)
        context.close(promise: nil)
    }
}

// MARK: - Errors

/// Errors specific to UnixSocketServer.
public enum UnixSocketServerError: Error, Sendable {
    /// The server is already running.
    case alreadyRunning

    /// The server has been stopped and cannot be restarted.
    case serverStopped

    /// Failed to decode received data.
    case decodeError(Error)
}

// MARK: - Length-Prefixed Message Decoder

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
