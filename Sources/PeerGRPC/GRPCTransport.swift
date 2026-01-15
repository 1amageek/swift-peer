import Foundation
import Peer
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

/// gRPC-based client transport for connecting to a remote server.
///
/// `GRPCTransport` represents a single client connection to a gRPC server.
/// For accepting multiple client connections, use `GRPCServer` instead.
///
/// ## Usage
///
/// ```swift
/// let transport = GRPCTransport(configuration: .connect(host: "localhost", port: 50051))
/// try await transport.start()
///
/// // Send messages
/// try await transport.send(.invocation(envelope))
///
/// // Receive messages
/// for try await envelope in transport.messages {
///     switch envelope {
///     case .invocation(let inv):
///         // Handle incoming invocation
///     case .response(let res):
///         // Handle response
///     }
/// }
///
/// // Cleanup
/// await transport.stop()
/// ```
///
/// ## Connection Lifecycle
///
/// 1. Create with `Configuration.connect(host:port:)`
/// 2. Call `start()` to establish connection
/// 3. Use `send()` and `messages` for communication
/// 4. Call `stop()` when done
///
/// After `stop()` is called:
/// - `send()` throws `GRPCTransportError.alreadyClosed`
/// - `messages` stream finishes
///
public final class GRPCTransport: DistributedTransport, Sendable {

    // MARK: - Type Aliases

    private typealias ClientTransportType = HTTP2ClientTransport.Posix

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let host: String
        public let port: Int

        /// Optional peer ID to identify this client to the server.
        /// Sent as `x-peer-id` metadata header.
        public let peerID: String?

        public init(host: String, port: Int, peerID: String? = nil) {
            self.host = host
            self.port = port
            self.peerID = peerID
        }

        /// Create a client configuration for connecting to a server.
        ///
        /// - Parameters:
        ///   - host: The server hostname or IP address.
        ///   - port: The server port.
        ///   - peerID: Optional peer ID to identify this client.
        /// - Returns: A client configuration.
        public static func connect(host: String, port: Int, peerID: String? = nil) -> Configuration {
            Configuration(host: host, port: port, peerID: peerID)
        }
    }

    // MARK: - Connection State

    private enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case closing
        case closed
    }

    // MARK: - Mutable State

    private struct MutableState: ~Copyable {
        var client: GRPCClient<ClientTransportType>?
        var clientTask: Task<Void, Error>?
        var streamTask: Task<Void, Never>?
        var outgoingContinuation: AsyncStream<EnvelopeMessage>.Continuation?
        var connectionState: ConnectionState = .disconnected
    }

    // MARK: - Properties

    private let configuration: Configuration
    private let mutableState: Mutex<MutableState>
    private let messageStream: AsyncThrowingStream<Envelope, Error>
    private let messageContinuation: AsyncThrowingStream<Envelope, Error>.Continuation

    // MARK: - DistributedTransport

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
        let currentState = mutableState.withLock { state -> ConnectionState in
            let current = state.connectionState
            if current == .disconnected {
                state.connectionState = .connecting
            }
            return current
        }

        switch currentState {
        case .disconnected:
            break // proceed
        case .connecting, .connected:
            throw GRPCTransportError.alreadyConnected
        case .closing, .closed:
            throw GRPCTransportError.alreadyClosed
        }

        do {
            try await startClient()
        } catch {
            // Only reset to disconnected if we're still in connecting state.
            // If stop() was called during startClient(), state is now closed
            // and we should NOT reset it to disconnected (which would allow restart).
            mutableState.withLock { state in
                if state.connectionState == .connecting {
                    state.connectionState = .disconnected
                }
            }
            throw error
        }
    }

    // MARK: - DistributedTransport: send

    public func send(_ envelope: Envelope) async throws {
        let continuation = mutableState.withLock { state -> AsyncStream<EnvelopeMessage>.Continuation? in
            switch state.connectionState {
            case .connected:
                return state.outgoingContinuation
            case .disconnected, .connecting, .closing, .closed:
                return nil
            }
        }

        guard let continuation else {
            throw GRPCTransportError.notConnected
        }

        continuation.yield(EnvelopeMessage(envelope: envelope))
    }

    // MARK: - DistributedTransport: stop

    public func stop() async {
        let (client, clientTask, streamTask, outgoingContinuation) = mutableState.withLock { state -> (
            GRPCClient<ClientTransportType>?,
            Task<Void, Error>?,
            Task<Void, Never>?,
            AsyncStream<EnvelopeMessage>.Continuation?
        ) in
            guard state.connectionState != .closing && state.connectionState != .closed else {
                return (nil, nil, nil, nil)
            }

            state.connectionState = .closing

            let result = (state.client, state.clientTask, state.streamTask, state.outgoingContinuation)

            state.client = nil
            state.clientTask = nil
            state.streamTask = nil
            state.outgoingContinuation = nil
            state.connectionState = .closed

            return result
        }

        // Cleanup
        outgoingContinuation?.finish()
        streamTask?.cancel()
        client?.beginGracefulShutdown()
        clientTask?.cancel()

        messageContinuation.finish()
    }

    // MARK: - Private: Client Setup

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

        // Atomically check state and set resources
        // If stop() was called during async operations above, don't proceed
        let shouldProceed = mutableState.withLock { state -> Bool in
            guard state.connectionState == .connecting else {
                return false  // stop() was called, don't proceed
            }
            state.client = client
            state.clientTask = clientTask
            state.outgoingContinuation = outgoingContinuation
            state.connectionState = .connected
            return true
        }

        if !shouldProceed {
            // Cancelled - clean up resources that were created
            outgoingContinuation.finish()
            client.beginGracefulShutdown()
            clientTask.cancel()
            throw GRPCTransportError.alreadyClosed
        }

        // Start bidirectional streaming
        let streamTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // Build metadata with peer ID if provided
                var metadata = Metadata()
                if let peerID = configuration.peerID {
                    metadata.addString(peerID, forKey: "x-peer-id")
                }

                let request = StreamingClientRequest<EnvelopeMessage>(
                    metadata: metadata,
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

                // Stream ended normally
                self.handleStreamEnded()
            } catch {
                self.handleStreamError(error)
            }
        }

        mutableState.withLock {
            $0.streamTask = streamTask
        }
    }

    // MARK: - Private: Stream Lifecycle

    private func handleStreamEnded() {
        let (shouldFinish, client, clientTask) = mutableState.withLock { state -> (
            Bool,
            GRPCClient<ClientTransportType>?,
            Task<Void, Error>?
        ) in
            guard state.connectionState == .connected else {
                return (false, nil, nil)
            }
            state.connectionState = .closed
            state.outgoingContinuation = nil

            // Capture and clear all resources atomically
            let c = state.client
            let t = state.clientTask
            state.client = nil
            state.clientTask = nil

            return (true, c, t)
        }

        if shouldFinish {
            // Clean up all resources
            client?.beginGracefulShutdown()
            clientTask?.cancel()
            messageContinuation.finish()
        }
    }

    private func handleStreamError(_ error: Error) {
        let (shouldFinish, client, clientTask) = mutableState.withLock { state -> (
            Bool,
            GRPCClient<ClientTransportType>?,
            Task<Void, Error>?
        ) in
            guard state.connectionState == .connected else {
                return (false, nil, nil)
            }
            state.connectionState = .closed
            state.outgoingContinuation = nil

            // Capture and clear all resources atomically
            let c = state.client
            let t = state.clientTask
            state.client = nil
            state.clientTask = nil

            return (true, c, t)
        }

        if shouldFinish {
            // Clean up all resources
            client?.beginGracefulShutdown()
            clientTask?.cancel()
            messageContinuation.finish(throwing: error)
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

/// Errors specific to GRPCTransport.
public enum GRPCTransportError: Error, Sendable {
    /// Not connected to the server.
    case notConnected

    /// Already connected to the server.
    case alreadyConnected

    /// The transport has been closed.
    case alreadyClosed

    /// Failed to connect to the server.
    case connectionFailed(String)
}
