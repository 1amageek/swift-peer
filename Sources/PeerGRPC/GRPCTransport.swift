import Foundation
import Peer
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

/// gRPC-based implementation of DistributedTransport for distributed actor communication.
///
/// This transport uses gRPC to send and receive InvocationEnvelope/ResponseEnvelope
/// for Swift distributed actors.
///
/// ## Usage
///
/// ```swift
/// let transport = GRPCTransport(
///     configuration: .server(host: "0.0.0.0", port: 50051)
/// )
///
/// // For actor system integration
/// let system = MyActorSystem(transport: transport)
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
            /// Server mode: accepts incoming invocations
            case server
            /// Client mode: connects to a remote server
            case client
            /// Both: server that also connects to other peers
            case peer
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

        public static func peer(host: String = "0.0.0.0", port: Int = 50051) -> Configuration {
            Configuration(mode: .peer, host: host, port: port)
        }
    }

    // MARK: - Mutable State

    private struct MutableState: ~Copyable {
        var server: GRPCServer<ServerTransportType>?
        var serverTask: Task<Void, Error>?
        var client: GRPCClient<ClientTransportType>?
        var clientTask: Task<Void, Error>?
        var boundPort: Int?
        var isClosed: Bool = false
    }

    // MARK: - Properties

    private let configuration: Configuration
    private let mutableState: Mutex<MutableState>
    private let pendingResponses: PendingResponses
    private let invocationStream: AsyncThrowingStream<InvocationEnvelope, Error>
    private let invocationContinuation: AsyncThrowingStream<InvocationEnvelope, Error>.Continuation

    /// The port the server is bound to (available after starting in server/peer mode)
    public var boundPort: Int? {
        mutableState.withLock { $0.boundPort }
    }

    // MARK: - DistributedTransport: incomingInvocations

    public var incomingInvocations: AsyncThrowingStream<InvocationEnvelope, Error> {
        invocationStream
    }

    // MARK: - Initialization

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.mutableState = Mutex(MutableState())
        self.pendingResponses = PendingResponses()

        // Create the invocation stream
        var continuation: AsyncThrowingStream<InvocationEnvelope, Error>.Continuation!
        self.invocationStream = AsyncThrowingStream { cont in
            continuation = cont
        }
        self.invocationContinuation = continuation
    }

    // MARK: - DistributedTransport: open

    /// Opens the transport for communication.
    ///
    /// - Throws: `GRPCTransportError.alreadyClosed` if the transport has been closed.
    public func open() async throws {
        let isClosed = mutableState.withLock { $0.isClosed }
        if isClosed {
            throw GRPCTransportError.alreadyClosed
        }

        switch configuration.mode {
        case .server:
            try await startServer()
        case .client:
            try await startClient()
        case .peer:
            try await startServer()
            try await startClient()
        }
    }

    // MARK: - DistributedTransport: sendInvocation (Client Side)

    public func sendInvocation(_ envelope: InvocationEnvelope) async throws -> ResponseEnvelope {
        guard let client = mutableState.withLock({ $0.client }) else {
            throw GRPCTransportError.notConnected
        }

        let request = ClientRequest(message: InvokeRequest(envelope: envelope))

        let response: InvokeResponse = try await client.unary(
            request: request,
            descriptor: MethodDescriptor.invoke,
            serializer: MessageSerializer<InvokeRequest>(),
            deserializer: MessageDeserializer<InvokeResponse>(),
            options: .defaults
        ) { response in
            try response.message
        }

        return response.envelope
    }

    // MARK: - DistributedTransport: sendResponse (Server Side)

    public func sendResponse(_ envelope: ResponseEnvelope) async throws {
        await pendingResponses.complete(callID: envelope.callID, with: envelope)
    }

    // MARK: - DistributedTransport: close

    public func close() async throws {
        mutableState.withLock { state in
            guard !state.isClosed else { return }
            state.isClosed = true

            // Stop server
            state.server?.beginGracefulShutdown()
            state.serverTask?.cancel()
            state.serverTask = nil
            state.server = nil

            // Stop client
            state.client?.beginGracefulShutdown()
            state.clientTask?.cancel()
            state.clientTask = nil
            state.client = nil
        }

        invocationContinuation.finish(throwing: nil)
    }

    // MARK: - Private: Server

    private func startServer() async throws {
        let service = GRPCTransportService(
            invocationContinuation: invocationContinuation,
            pendingResponses: pendingResponses
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

        if let address = try await grpcServer.listeningAddress {
            let port: Int
            if let ipv4 = address.ipv4 {
                port = ipv4.port
            } else if let ipv6 = address.ipv6 {
                port = ipv6.port
            } else {
                port = configuration.port
            }
            mutableState.withLock { $0.boundPort = port }
        } else {
            throw GRPCTransportError.serverBindFailed
        }
    }

    // MARK: - Private: Client

    private func startClient() async throws {
        let transport = try ClientTransportType(
            target: .ipv4(address: configuration.host, port: configuration.port),
            transportSecurity: .plaintext
        )

        let client = GRPCClient(transport: transport)

        let task = Task {
            try await client.runConnections()
        }

        mutableState.withLock {
            $0.client = client
            $0.clientTask = task
        }
    }
}

// MARK: - Method Descriptors

extension MethodDescriptor {
    static let invoke = MethodDescriptor(
        fullyQualifiedService: "actor.Transport",
        method: "Invoke"
    )
}

// MARK: - Errors

public enum GRPCTransportError: Error, Sendable {
    /// No client connection is available to send invocations.
    case notConnected

    /// The server failed to bind to the specified port.
    case serverBindFailed

    /// The transport has been closed and cannot be reopened.
    /// Create a new GRPCTransport instance instead.
    case alreadyClosed
}
