import Foundation

/// Events emitted by a transport.
public enum TransportEvent: Sendable {
    /// The transport has started.
    case started

    /// The transport has stopped.
    case stopped

    /// A peer has connected.
    case peerConnected(PeerID)

    /// A peer has disconnected.
    case peerDisconnected(PeerID)

    /// Data was received from a peer.
    case dataReceived(from: PeerID, data: Data)

    /// An error occurred.
    case error(TransportError)
}

/// Errors that can occur in transport operations.
public enum TransportError: Error, Sendable {
    /// The transport has not been started.
    case notStarted

    /// The transport is already started.
    case alreadyStarted

    /// Connection to a peer failed (with peer ID).
    case connectionFailed(PeerID, String)

    /// Connection failed (generic).
    case connectionError(String)

    /// Failed to send data to a peer.
    case sendFailed(PeerID, String)

    /// The connection was closed.
    case connectionClosed

    /// Operation timed out.
    case timeout

    /// The peer is not connected.
    case notConnected(PeerID)

    /// Could not resolve the peer.
    case resolutionFailed(PeerID)

    /// Invalid data received.
    case invalidData(String)
}
