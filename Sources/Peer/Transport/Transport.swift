import Foundation

/// Protocol defining a transport mechanism for peer communication.
///
/// Transport implementations handle the low-level details of sending
/// and receiving data between peers. This protocol focuses on:
/// - Starting and stopping the transport
/// - Sending data to peers
/// - Tracking connected peers
///
/// Discovery of peers is handled separately by `PeerDiscovery`.
///
/// ## Example Usage
///
/// ```swift
/// let transport: Transport = GRPCTransport(...)
///
/// try await transport.start()
///
/// let response = try await transport.send(
///     to: peerID,
///     data: requestData,
///     timeout: .seconds(5)
/// )
///
/// try await transport.stop()
/// ```
public protocol Transport: Sendable {
    /// Information about the local peer.
    var localPeerInfo: PeerInfo { get }

    // MARK: - Lifecycle

    /// Start the transport.
    ///
    /// This may start a server, establish connections, or perform
    /// other initialization as needed by the implementation.
    func start() async throws

    /// Stop the transport.
    ///
    /// This should gracefully close all connections and release resources.
    func stop() async throws

    // MARK: - Communication

    /// Send data to a peer and wait for a response.
    ///
    /// - Parameters:
    ///   - peerID: The peer to send data to.
    ///   - data: The data to send.
    ///   - timeout: Maximum time to wait for a response.
    /// - Returns: The response data.
    /// - Throws: `TransportError` if the send fails.
    func send(to peerID: PeerID, data: Data, timeout: Duration) async throws -> Data

    // MARK: - Connection State

    /// List of currently connected peer IDs.
    var connectedPeers: [PeerID] { get async }

    // MARK: - Events

    /// Stream of transport events.
    ///
    /// Subscribe to this stream to receive notifications about
    /// peer connections, disconnections, and errors.
    var events: AsyncStream<TransportEvent> { get async }
}
