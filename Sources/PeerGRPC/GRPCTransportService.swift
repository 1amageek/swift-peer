import Foundation
import Peer
import GRPCCore

/// gRPC service implementation for bidirectional streaming.
///
/// Handles the Stream RPC method, enabling true bidirectional communication
/// between client and server.
struct GRPCTransportService: RegistrableRPCService, Sendable {

    /// Continuation for pushing incoming messages to the transport
    let messageContinuation: AsyncThrowingStream<Envelope, Error>.Continuation

    /// Callback to set the outgoing continuation when a client connects
    let getOutgoingContinuation: @Sendable (AsyncStream<EnvelopeMessage>.Continuation) -> Void

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: MethodDescriptor.stream,
            deserializer: MessageDeserializer<EnvelopeMessage>(),
            serializer: MessageSerializer<EnvelopeMessage>()
        ) { request, context in
            await self.handleStream(request: request, context: context)
        }
    }

    // MARK: - Stream Handler

    private func handleStream(
        request: StreamingServerRequest<EnvelopeMessage>,
        context: ServerContext
    ) async -> StreamingServerResponse<EnvelopeMessage> {

        StreamingServerResponse { writer in
            // Create outgoing stream for server -> client messages
            let (outgoingStream, outgoingContinuation) = AsyncStream<EnvelopeMessage>.makeStream()

            // Provide the continuation to the transport
            getOutgoingContinuation(outgoingContinuation)

            // Task to write outgoing messages
            let writeTask = Task {
                for await message in outgoingStream {
                    try await writer.write(message)
                }
            }

            // Process incoming messages from client
            do {
                for try await message in request.messages {
                    messageContinuation.yield(message.envelope)
                }
            } catch {
                messageContinuation.finish(throwing: error)
            }

            // Cleanup
            writeTask.cancel()
            outgoingContinuation.finish()

            return [:]
        }
    }
}
