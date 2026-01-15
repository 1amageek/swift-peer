import Foundation
import Peer

/// Represents an incoming connection from a remote peer.
public struct IncomingConnection: Sendable {
    /// The peer ID of the connecting peer.
    public let peerID: PeerID

    /// The transport for sending/receiving messages with this peer.
    public let transport: any DistributedTransport

    public init(peerID: PeerID, transport: any DistributedTransport) {
        self.peerID = peerID
        self.transport = transport
    }
}
