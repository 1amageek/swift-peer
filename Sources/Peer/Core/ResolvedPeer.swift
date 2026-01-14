import Foundation

/// Detailed information about a resolved peer.
///
/// ResolvedPeer contains cached information about a peer obtained via resolution.
/// It includes metadata and a TTL for cache invalidation.
public struct ResolvedPeer: Sendable, Hashable {
    /// The identifier of this peer.
    public let peerID: PeerID

    /// Display name for this peer.
    public let displayName: String

    /// Metadata associated with this peer.
    public let metadata: [String: String]

    /// When this peer information was resolved.
    public let resolvedAt: Date

    /// Time-to-live duration for this resolution.
    public let ttl: Duration

    /// Creates a new ResolvedPeer.
    ///
    /// - Parameters:
    ///   - peerID: The identifier of the peer.
    ///   - displayName: Human-readable name for the peer.
    ///   - metadata: Optional metadata about the peer.
    ///   - resolvedAt: When the resolution occurred (defaults to now).
    ///   - ttl: Time-to-live for this resolution (defaults to 5 minutes).
    public init(
        peerID: PeerID,
        displayName: String? = nil,
        metadata: [String: String] = [:],
        resolvedAt: Date = Date(),
        ttl: Duration = .seconds(300)
    ) {
        self.peerID = peerID
        self.displayName = displayName ?? peerID.value
        self.metadata = metadata
        self.resolvedAt = resolvedAt
        self.ttl = ttl
    }

    /// Whether this resolution is still valid.
    public var isValid: Bool {
        Date() < resolvedAt.addingTimeInterval(ttl.timeInterval)
    }
}

// MARK: - Duration Extension

extension Duration {
    /// Convert Duration to TimeInterval.
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000
    }
}
