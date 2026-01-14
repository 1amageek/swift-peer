import Foundation

/// Information for advertising a service on the network.
///
/// ServiceInfo is used by PeerDiscovery implementations to advertise
/// a peer's presence on the network. It contains the service name,
/// port, and optional metadata.
public struct ServiceInfo: Sendable, Hashable {
    /// The name to advertise (e.g., the peer's display name).
    public let name: String

    /// The port number the service is listening on.
    public let port: Int

    /// Additional metadata to include in the advertisement.
    public let metadata: [String: String]

    /// Creates a new ServiceInfo.
    ///
    /// - Parameters:
    ///   - name: The name to advertise.
    ///   - port: The port number.
    ///   - metadata: Optional metadata to include.
    public init(name: String, port: Int, metadata: [String: String] = [:]) {
        self.name = name
        self.port = port
        self.metadata = metadata
    }
}
