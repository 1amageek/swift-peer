import Foundation

/// Network endpoint information for connecting to a peer.
///
/// Endpoint contains the host and port information needed to establish
/// a connection to a peer. This is transport-agnostic - the same endpoint
/// can be used with gRPC, WebSocket, or other transport implementations.
public struct Endpoint: Sendable, Hashable, Codable {
    /// The hostname or IP address.
    public let host: String

    /// The port number.
    public let port: Int

    /// Creates a new Endpoint.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address.
    ///   - port: The port number.
    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

extension Endpoint: CustomStringConvertible {
    public var description: String {
        "\(host):\(port)"
    }
}
