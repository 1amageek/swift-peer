import Foundation

/// A peer discovered on the network.
///
/// DiscoveredPeer contains all the information needed to connect to
/// and identify a peer that was found through discovery. It includes
/// the peer's identity, endpoint for connection, and any metadata
/// the peer advertised.
public struct DiscoveredPeer: Sendable, Hashable {
    /// The unique identifier for this peer.
    public let peerID: PeerID

    /// Human-readable name of this peer.
    public let name: String

    /// Network endpoint for connecting to this peer.
    public let endpoint: Endpoint

    /// Additional metadata advertised by this peer.
    public let metadata: [String: String]

    /// When this peer was discovered.
    public let discoveredAt: Date

    /// Creates a new DiscoveredPeer.
    ///
    /// - Parameters:
    ///   - peerID: The unique identifier for this peer.
    ///   - name: Human-readable name.
    ///   - endpoint: Network endpoint for connection.
    ///   - metadata: Additional metadata.
    ///   - discoveredAt: When this peer was discovered (defaults to now).
    public init(
        peerID: PeerID,
        name: String,
        endpoint: Endpoint,
        metadata: [String: String] = [:],
        discoveredAt: Date = Date()
    ) {
        self.peerID = peerID
        self.name = name
        self.endpoint = endpoint
        self.metadata = metadata
        self.discoveredAt = discoveredAt
    }
}
