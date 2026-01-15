import Foundation

/// A server that accepts incoming transport connections.
///
/// `TransportServer` provides a pattern for accepting multiple client connections,
/// where each connection becomes a separate `DistributedTransport` instance.
/// This enables proper 1:1 connection semantics while supporting multiple clients.
///
/// ## Architecture
///
/// ```
/// TransportServer (e.g., GRPCServer)
///       │
///       ├── connections stream
///       │
///       ▼
/// ┌─────────────────┐
/// │ Connection 1    │ → DistributedTransport
/// │ Connection 2    │ → DistributedTransport
/// │ Connection N    │ → DistributedTransport
/// └─────────────────┘
/// ```
///
/// ## Usage
///
/// ```swift
/// let server = GRPCServer(configuration: .listen(port: 50051))
/// try await server.start()
///
/// // Handle each connection as a separate transport
/// for try await connection in server.connections {
///     let peerID = connection.connectionID
///     mesh.addRoute(to: peerID, via: connection)
///
///     // Handle messages from this connection
///     Task {
///         for try await envelope in connection.messages {
///             // Process message
///         }
///     }
/// }
///
/// // Cleanup
/// await server.stop()
/// ```
///
public protocol TransportServer: Sendable {
    /// The type of connection this server produces.
    associatedtype Connection: DistributedTransport

    /// The address the server is bound to after starting.
    ///
    /// Returns `nil` if the server has not been started or binding failed.
    var boundAddress: String? { get async }

    /// Start the server and begin accepting connections.
    ///
    /// After calling this method, new connections will appear in the
    /// `connections` stream.
    ///
    /// - Throws: Server-specific errors if binding fails (e.g., port in use).
    func start() async throws

    /// Stop the server and close all connections.
    ///
    /// This will:
    /// - Stop accepting new connections
    /// - Close all existing connections
    /// - Finish the `connections` stream
    func stop() async

    /// A stream of new connections.
    ///
    /// Each yielded connection is a fully initialized `DistributedTransport`
    /// ready for communication. The stream finishes when the server stops
    /// or throws an error if the server encounters a fatal error.
    var connections: AsyncThrowingStream<Connection, Error> { get }
}

/// Errors that can occur in transport server operations.
public enum TransportServerError: Error, Sendable {
    /// Failed to bind to the specified address.
    case bindFailed(String)

    /// Server is already running.
    case alreadyRunning

    /// Server has been stopped and cannot be restarted.
    case stopped

    /// Failed to accept a connection.
    case acceptFailed(String)
}
