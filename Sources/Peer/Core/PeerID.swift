import Foundation

/// A simple identifier for a peer in the discovery system.
///
/// PeerID is a lightweight wrapper around a string value that identifies
/// a peer in the network. Unlike more specialized implementations, this
/// generic PeerID does not impose any naming conventions or validation rules.
public struct PeerID: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The raw string value of the peer identifier.
    public let value: String

    /// Creates a new PeerID with the given value.
    ///
    /// - Parameter value: The string identifier for the peer.
    public init(_ value: String) {
        self.value = value
    }

    public var description: String { value }

    /// A broadcast PeerID representing all peers.
    public static let broadcast = PeerID("")

    /// Whether this is the broadcast PeerID.
    public var isBroadcast: Bool { value.isEmpty }
}

extension PeerID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.value = value
    }
}
