import Foundation
import Peer

/// Errors that can occur when using PeerNode.
public enum PeerNodeError: Error, LocalizedError, Sendable {
    /// The specified port is already in use.
    case portUnavailable(port: Int)

    /// Failed to start the node.
    case startFailed(String)

    /// Failed to connect to a peer.
    case connectionFailed(peer: PeerID, reason: String)

    /// The node has not been started yet.
    case notStarted

    /// The node has already been started.
    case alreadyStarted

    /// The node has been stopped.
    case alreadyStopped

    /// Failed to advertise the node on the network.
    case advertisingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .portUnavailable(let port):
            return "Port \(port) is already in use"
        case .startFailed(let reason):
            return "Failed to start node: \(reason)"
        case .connectionFailed(let peer, let reason):
            return "Failed to connect to \(peer.value): \(reason)"
        case .notStarted:
            return "Node has not been started"
        case .alreadyStarted:
            return "Node has already been started"
        case .alreadyStopped:
            return "Node has been stopped"
        case .advertisingFailed(let reason):
            return "Failed to advertise: \(reason)"
        }
    }
}
