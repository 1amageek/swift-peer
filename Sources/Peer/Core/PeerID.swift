import Foundation

/// Identifier for a peer in the P2P mesh network.
///
/// PeerID contains both the peer's display name and connection information,
/// enabling transparent routing regardless of whether the peer is local or remote.
///
/// ## Format
///
/// PeerID uses the format `name@host:port`:
/// - `name`: Display name for the peer (e.g., "alice")
/// - `host`: IP address or hostname (e.g., "192.168.1.10")
/// - `port`: Port number (e.g., 50051)
///
/// ## Usage
///
/// ```swift
/// // Create with components
/// let peerID = PeerID(name: "alice", host: "192.168.1.10", port: 50051)
///
/// // Parse from string
/// let peerID = PeerID("alice@192.168.1.10:50051")
///
/// // Access components
/// print(peerID.name)  // "alice"
/// print(peerID.host)  // "192.168.1.10"
/// print(peerID.port)  // 50051
/// ```
///
public struct PeerID: Sendable, Hashable, Codable, CustomStringConvertible {

    /// Display name for the peer.
    public let name: String

    /// Host address (IP or hostname).
    public let host: String

    /// Port number.
    public let port: Int

    /// Creates a PeerID with the specified components.
    ///
    /// - Parameters:
    ///   - name: Display name for the peer.
    ///   - host: Host address (IP or hostname).
    ///   - port: Port number.
    public init(name: String, host: String, port: Int) {
        self.name = name
        self.host = host
        self.port = port
    }

    /// Creates a PeerID by parsing a string in `name@host:port` format.
    ///
    /// - Parameter value: String in `name@host:port` format.
    /// - Returns: nil if the format is invalid.
    public init?(_ value: String) {
        guard let parsed = Self.parse(value) else {
            return nil
        }
        self.name = parsed.name
        self.host = parsed.host
        self.port = parsed.port
    }

    /// The full address string (`host:port`).
    public var address: String {
        "\(host):\(port)"
    }

    /// String representation in `name@host:port` format.
    public var description: String {
        "\(name)@\(host):\(port)"
    }

    /// The raw string value (same as description, for compatibility).
    public var value: String {
        description
    }

    // MARK: - Parsing

    private static func parse(_ value: String) -> (name: String, host: String, port: Int)? {
        // Format: name@host:port
        guard let atIndex = value.lastIndex(of: "@") else {
            return nil
        }

        let name = String(value[..<atIndex])
        let addressPart = String(value[value.index(after: atIndex)...])

        guard let colonIndex = addressPart.lastIndex(of: ":") else {
            return nil
        }

        let host = String(addressPart[..<colonIndex])
        let portString = String(addressPart[addressPart.index(after: colonIndex)...])

        guard let port = Int(portString), port > 0, port <= 65535 else {
            return nil
        }

        guard !name.isEmpty, !host.isEmpty else {
            return nil
        }

        return (name, host, port)
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let parsed = Self.parse(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid PeerID format: \(value). Expected name@host:port"
            )
        }
        self.name = parsed.name
        self.host = parsed.host
        self.port = parsed.port
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: - Special Values

    /// A broadcast PeerID representing all peers.
    /// Note: This is a sentinel value and should not be used for actual routing.
    public static let broadcast = PeerID(name: "", host: "", port: 0)

    /// Whether this is the broadcast PeerID.
    public var isBroadcast: Bool {
        name.isEmpty && host.isEmpty && port == 0
    }
}

// MARK: - ExpressibleByStringLiteral

extension PeerID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        if let parsed = Self.parse(value) {
            self.name = parsed.name
            self.host = parsed.host
            self.port = parsed.port
        } else {
            // Fallback for invalid literals (will be caught at runtime)
            self.name = value
            self.host = "localhost"
            self.port = 0
        }
    }
}
