import Foundation

/// Information about the local peer.
///
/// PeerInfo is used by Transport implementations to identify the local peer
/// in the network. It contains the peer's unique identifier and display name.
public struct PeerInfo: Sendable, Hashable, Codable {
    /// The unique identifier for this peer.
    public let peerID: PeerID

    /// Human-readable display name for this peer.
    public let displayName: String

    /// Creates a new PeerInfo.
    ///
    /// - Parameters:
    ///   - peerID: The unique identifier for this peer.
    ///   - displayName: Human-readable display name.
    public init(peerID: PeerID, displayName: String) {
        self.peerID = peerID
        self.displayName = displayName
    }

    /// Creates a new PeerInfo with the peer ID as the display name.
    ///
    /// - Parameter peerID: The unique identifier for this peer.
    public init(peerID: PeerID) {
        self.peerID = peerID
        self.displayName = peerID.value
    }
}
