import Foundation

/// Protocol for discovering peers on the network.
///
/// PeerDiscovery implementations handle finding other peers and
/// advertising the local peer's presence. This is separate from
/// Transport, which handles actual data communication.
///
/// ## Example Usage
///
/// ```swift
/// let discovery = LocalNetworkDiscovery(serviceType: "_myapp._tcp")
///
/// // Advertise our presence
/// try await discovery.advertise(info: ServiceInfo(
///     name: "MyDevice",
///     port: 50051,
///     metadata: ["version": "1.0"]
/// ))
///
/// // Discover other peers
/// for try await peer in discovery.discover(timeout: .seconds(5)) {
///     print("Found: \(peer.name) at \(peer.endpoint)")
/// }
///
/// // Stop advertising
/// try await discovery.stopAdvertising()
/// ```
public protocol PeerDiscovery: Sendable {
    /// Discover peers on the network.
    ///
    /// Returns a stream of discovered peers. The stream will complete
    /// after the timeout duration, or can be cancelled early.
    ///
    /// - Parameter timeout: Maximum time to wait for discoveries.
    /// - Returns: An async stream of discovered peers.
    func discover(timeout: Duration) async -> AsyncThrowingStream<DiscoveredPeer, Error>

    /// Advertise this peer's presence on the network.
    ///
    /// - Parameter info: Information about the service to advertise.
    /// - Throws: `DiscoveryError.advertisingFailed` if advertising fails.
    func advertise(info: ServiceInfo) async throws

    /// Stop advertising this peer's presence.
    ///
    /// - Throws: `DiscoveryError` if stopping fails.
    func stopAdvertising() async throws

    /// Stream of discovery events.
    ///
    /// Subscribe to this stream to receive notifications about
    /// peer appearances, disappearances, and errors.
    var events: AsyncStream<DiscoveryEvent> { get async }
}
