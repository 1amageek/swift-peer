import Foundation
import Peer
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCNIOTransportCore
import Synchronization

/// gRPC-based implementation of DistributedTransport with bidirectional streaming.
///
/// Supports true bidirectional communication - both sides can send
/// invocations and responses at any time.
///
/// ## Usage
///
/// ```swift
/// let transport = GRPCTransport(configuration: .server(port: 50051))
/// try await transport.start()
///
/// // Send
/// try await transport.send(.invocation(envelope))
///
/// // Receive
/// for try await envelope in transport.messages {
///     switch envelope {
///     case .invocation(let inv):
///         // Handle incoming invocation
///     case .response(let res):
///         // Handle response
///     }
/// }
/// ```
public final class GRPCTransport: DistributedTransport, Sendable {

    // MARK: - Type Aliases

    private typealias ServerTransportType = HTTP2ServerTransport.Posix
    private typealias ClientTransportType = HTTP2ClientTransport.Posix

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let mode: Mode
        public let host: String
        public let port: Int

        public enum Mode: Sendable {
            /// Server mode: accepts incoming connections
            case server
            /// Client mode: connects to a remote server
            case client
        }

        public init(mode: Mode, host: String, port: Int) {
            self.mode = mode
            self.host = host
            self.port = port
        }

        public static func server(host: String = "0.0.0.0", port: Int = 50051) -> Configuration {
            Configuration(mode: .server, host: host, port: port)
        }

        public static func client(host: String, port: Int) -> Configuration {
            Configuration(mode: .client, host: host, port: port)
        }
    }

    // MARK: - Mutable State

    private struct MutableState: ~Copyable {
        var server: GRPCServer<ServerTransportType>?
        var serverTask: Task<Void, Error>?
        var client: GRPCClient<ClientTransportType>?
        var clientTask: Task<Void, Error>?
        var streamTask: Task<Void, Never>?
        var outgoingContinuation: AsyncStream<EnvelopeMessage>.Continuation?
        var boundPort: Int?
        var isClosed: Bool = false
    }

    // MARK: - Properties

    private let configuration: Configuration
    private let mutableState: Mutex<MutableState>
    private let messageStream: AsyncThrowingStream<Envelope, Error>
    private let messageContinuation: AsyncThrowingStream<Envelope, Error>.Continuation

    /// The port the server is bound to (available after starting in server mode)
    public var boundPort: Int? {
        mutableState.withLock { $0.boundPort }
    }

    // MARK: - DistributedTransport: messages

    public var messages: AsyncThrowingStream<Envelope, Error> {
        messageStream
    }

    // MARK: - Initialization

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.mutableState = Mutex(MutableState())

        var continuation: AsyncThrowingStream<Envelope, Error>.Continuation!
        self.messageStream = AsyncThrowingStream { cont in
            continuation = cont
        }
        self.messageContinuation = continuation
    }

    // MARK: - DistributedTransport: start

    public func start() async throws {
        let isClosed = mutableState.withLock { $0.isClosed }
        if isClosed {
            throw GRPCTransportError.alreadyClosed
        }

        switch configuration.mode {
        case .server:
            try await startServer()
        case .client:
            try await startClient()
        }
    }

    // MARK: - DistributedTransport: send

    public func send(_ envelope: Envelope) async throws {
        guard let continuation = mutableState.withLock({ $0.outgoingContinuation }) else {
            throw GRPCTransportError.notConnected
        }
        continuation.yield(EnvelopeMessage(envelope: envelope))
    }

    // MARK: - DistributedTransport: stop

    public func stop() async {
        mutableState.withLock { state in
            guard !state.isClosed else { return }
            state.isClosed = true

            state.outgoingContinuation?.finish()
            state.outgoingContinuation = nil

            state.streamTask?.cancel()
            state.streamTask = nil

            state.server?.beginGracefulShutdown()
            state.serverTask?.cancel()
            state.serverTask = nil
            state.server = nil

            state.client?.beginGracefulShutdown()
            state.clientTask?.cancel()
            state.clientTask = nil
            state.client = nil
        }

        messageContinuation.finish()
    }

    // MARK: - Private: Server

    private func startServer() async throws {
        let service = GRPCTransportService(
            messageContinuation: messageContinuation,
            getOutgoingContinuation: { [weak self] continuation in
                self?.mutableState.withLock { $0.outgoingContinuation = continuation }
            }
        )

        let transport = ServerTransportType(
            address: .ipv4(host: configuration.host, port: configuration.port),
            transportSecurity: .plaintext
        )

        let grpcServer = GRPCServer(
            transport: transport,
            services: [service]
        )

        let task = Task {
            try await grpcServer.serve()
        }

        mutableState.withLock {
            $0.server = grpcServer
            $0.serverTask = task
        }

        guard let address = try await grpcServer.listeningAddress else {
            throw GRPCTransportError.serverBindFailed
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

    // MARK: - Private: Client

    private func startClient() async throws {
        let transport = try ClientTransportType(
            target: .ipv4(address: configuration.host, port: configuration.port),
            transportSecurity: .plaintext
        )

        let client = GRPCClient(transport: transport)

        let clientTask = Task {
            try await client.runConnections()
        }

        // Create outgoing stream
        let (outgoingStream, outgoingContinuation) = AsyncStream<EnvelopeMessage>.makeStream()

        mutableState.withLock {
            $0.client = client
            $0.clientTask = clientTask
            $0.outgoingContinuation = outgoingContinuation
        }

        // Start bidirectional streaming
        let streamTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let request = StreamingClientRequest<EnvelopeMessage>(
                    metadata: [:],
                    producer: { writer in
                        for await message in outgoingStream {
                            try await writer.write(message)
                        }
                    }
                )

                try await client.bidirectionalStreaming(
                    request: request,
                    descriptor: MethodDescriptor.stream,
                    serializer: MessageSerializer<EnvelopeMessage>(),
                    deserializer: MessageDeserializer<EnvelopeMessage>(),
                    options: .defaults
                ) { response in
                    for try await message in response.messages {
                        self.messageContinuation.yield(message.envelope)
                    }
                }
            } catch {
                self.messageContinuation.finish(throwing: error)
            }
        }

        mutableState.withLock {
            $0.streamTask = streamTask
        }
    }
}

// MARK: - Method Descriptors

extension MethodDescriptor {
    static let stream = MethodDescriptor(
        fullyQualifiedService: "actor.Transport",
        method: "Stream"
    )
}

// MARK: - Errors

public enum GRPCTransportError: Error, Sendable {
    case notConnected
    case serverBindFailed
    case alreadyClosed
}
