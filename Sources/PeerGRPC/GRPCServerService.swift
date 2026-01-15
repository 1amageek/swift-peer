import Foundation
import Peer
import GRPCCore

/// gRPC service implementation that creates per-connection transports.
///
/// Unlike the previous design where a single continuation was overwritten,
/// this service creates a new `GRPCServerConnection` for each client that connects.
/// Each connection is independent and can send/receive messages without interference.
///
/// ## Connection Flow
///
/// 1. Client initiates bidirectional streaming RPC
/// 2. Service extracts connection ID from metadata (or generates UUID)
/// 3. Creates `GRPCServerConnection` for this client
/// 4. Notifies via `onNewConnection` callback
/// 5. Forwards messages bidirectionally until stream ends
/// 6. Calls `handleStreamEnded()` on connection when done
///
struct GRPCServerService: RegistrableRPCService, Sendable {

    /// Callback when a new client connects.
    ///
    /// The connection is fully initialized and ready for use.
    let onNewConnection: @Sendable (GRPCServerConnection) -> Void

    // MARK: - RegistrableRPCService

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
            // Extract connection ID from metadata or generate one
            let connectionID = extractConnectionID(from: request.metadata) ?? UUID().uuidString

            // Create outgoing stream for server -> client messages
            let (outgoingStream, outgoingContinuation) = AsyncStream<EnvelopeMessage>.makeStream()

            // Create the per-connection transport
            let connection = GRPCServerConnection(
                connectionID: connectionID,
                outgoingContinuation: outgoingContinuation,
                onClose: {
                    // Connection closed - cleanup if needed
                    // The outgoing stream will naturally end
                }
            )

            // Notify about new connection
            onNewConnection(connection)

            // Task to write outgoing messages to the client
            let writeTask = Task {
                do {
                    for await message in outgoingStream {
                        try await writer.write(message)
                    }
                } catch {
                    // Write failed - connection will be closed
                }
            }

            // Process incoming messages from client
            do {
                for try await message in request.messages {
                    connection.yieldIncoming(message.envelope)
                }
            } catch {
                connection.handleError(error)
            }

            // Stream ended (client disconnected or error)
            writeTask.cancel()
            outgoingContinuation.finish()
            connection.handleStreamEnded()

            return [:]
        }
    }

    // MARK: - Private

    private func extractConnectionID(from metadata: Metadata) -> String? {
        // Try to get peer ID from metadata
        // Common header names: "x-peer-id", "peer-id", "client-id"
        //
        // Metadata subscript [stringValues: key] returns Metadata.StringValues,
        // which is a Sequence of Substring. We iterate to get the first value.
        for key in ["x-peer-id", "peer-id", "client-id"] {
            var iterator = metadata[stringValues: key].makeIterator()
            if let value = iterator.next() {
                return String(value)
            }
        }
        return nil
    }
}
