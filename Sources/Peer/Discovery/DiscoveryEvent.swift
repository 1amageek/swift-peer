import Foundation

/// Events emitted by a peer discovery mechanism.
public enum DiscoveryEvent: Sendable {
    /// A new peer appeared on the network.
    case peerAppeared(DiscoveredPeer)

    /// A peer disappeared from the network.
    case peerDisappeared(PeerID)

    /// Advertising has started.
    case advertisingStarted

    /// Advertising has stopped.
    case advertisingStopped

    /// An error occurred.
    case error(DiscoveryError)
}

/// Errors that can occur during peer discovery.
public enum DiscoveryError: Error, Sendable {
    /// Failed to start advertising.
    case advertisingFailed(String)

    /// Failed to discover peers.
    case discoveryFailed(String)

    /// Discovery timed out without finding any peers.
    case timeout

    /// Network is unavailable.
    case networkUnavailable

    /// The discovery mechanism is not supported on this platform.
    case notSupported
}
