import Foundation
import Peer

// MARK: - Invoke RPC Messages

/// Request message for Invoke RPC - wraps InvocationEnvelope for gRPC transport
struct InvokeRequest: Codable, Sendable {
    let envelope: InvocationEnvelope
}

/// Response message for Invoke RPC - wraps ResponseEnvelope for gRPC transport
struct InvokeResponse: Codable, Sendable {
    let envelope: ResponseEnvelope
}
