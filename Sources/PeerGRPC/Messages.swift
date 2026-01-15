import Foundation
import Peer

// MARK: - Bidirectional Streaming Message

/// Message for bidirectional streaming - wraps Envelope for gRPC transport
struct EnvelopeMessage: Codable, Sendable {
    let envelope: Envelope
}
