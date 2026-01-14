import Foundation
import Peer
import GRPCCore

/// gRPC service implementation for handling incoming invocations.
///
/// This service receives InvocationEnvelope from remote clients and forwards them
/// to the transport's incomingInvocations stream.
struct GRPCTransportService: RegistrableRPCService {

    /// Continuation for pushing incoming invocations to the stream
    let invocationContinuation: AsyncThrowingStream<InvocationEnvelope, Error>.Continuation

    /// Pending responses keyed by callID
    let pendingResponses: PendingResponses

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        // Register Invoke handler
        router.registerHandler(
            forMethod: MethodDescriptor.invoke,
            deserializer: MessageDeserializer<InvokeRequest>(),
            serializer: MessageSerializer<InvokeResponse>()
        ) { request, context in
            let singleRequest = try await ServerRequest(stream: request)
            let singleResponse = await self.handleInvoke(request: singleRequest)
            return StreamingServerResponse(single: singleResponse)
        }
    }

    // MARK: - Invoke Handler

    private func handleInvoke(request: ServerRequest<InvokeRequest>) async -> ServerResponse<InvokeResponse> {
        let envelope = request.message.envelope

        // Create a pending response slot
        let responseContinuation = await pendingResponses.createPending(for: envelope.callID)

        // Forward to incoming invocations stream
        invocationContinuation.yield(envelope)

        // Wait for response from the actor system
        let response = await responseContinuation.value

        return ServerResponse(message: InvokeResponse(envelope: response))
    }
}

// MARK: - Pending Responses Manager

/// Thread-safe manager for pending response continuations.
///
/// When an invocation arrives, we create a pending slot and wait for the
/// actor system to process it and call sendResponse.
actor PendingResponses {

    private var pending: [String: CheckedContinuation<ResponseEnvelope, Never>] = [:]

    /// Creates a pending response slot for the given callID.
    func createPending(for callID: String) async -> Task<ResponseEnvelope, Never> {
        Task {
            await withCheckedContinuation { continuation in
                self.pending[callID] = continuation
            }
        }
    }

    /// Completes the pending response for the given callID.
    func complete(callID: String, with response: ResponseEnvelope) {
        if let continuation = pending.removeValue(forKey: callID) {
            continuation.resume(returning: response)
        }
    }
}
