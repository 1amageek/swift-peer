import Testing
import Foundation
import Synchronization
@testable import PeerSocket
@testable import Peer

// MARK: - Test Helpers

/// Waits for the first value from an AsyncThrowingStream with timeout.
private func awaitFirst<T: Sendable>(
    from stream: AsyncThrowingStream<T, Error>,
    timeout: Duration = .seconds(5)
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            for try await value in stream {
                return value
            }
            throw TestError.streamEnded
        }

        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestError.timeout
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Waits for the first value from an AsyncStream with timeout.
private func awaitFirst<T: Sendable>(
    from stream: AsyncStream<T>,
    timeout: Duration = .seconds(5)
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            for await value in stream {
                return value
            }
            throw TestError.streamEnded
        }

        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestError.timeout
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private enum TestError: Error {
    case timeout
    case streamEnded
}

// MARK: - UnixSocketServer Tests

@Suite("UnixSocketServer Initialization")
struct UnixSocketServerInitTests {

    @Test("Server initialization")
    func serverInit() {
        let server = UnixSocketServer(path: "/tmp/test.sock")
        #expect(server.socketPath == "/tmp/test.sock")
    }
}

@Suite("UnixSocketServer Lifecycle")
struct UnixSocketServerLifecycleTests {

    @Test("Server start and stop")
    func serverStartStop() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketServer(path: testPath)
        try await server.start()

        // Verify socket file was created
        #expect(FileManager.default.fileExists(atPath: testPath))

        await server.stop()

        // Verify socket file was removed
        #expect(!FileManager.default.fileExists(atPath: testPath))
    }
}

// MARK: - UnixSocketTransport Tests

@Suite("UnixSocketTransport Initialization")
struct UnixSocketTransportInitTests {

    @Test("Client initialization")
    func clientInit() {
        let transport = UnixSocketTransport(path: "/tmp/test.sock")
        #expect(transport.socketPath == "/tmp/test.sock")
    }
}

@Suite("UnixSocketTransport Errors")
struct UnixSocketTransportErrorTests {

    @Test("Error cases exist")
    func errorCases() {
        let errors: [UnixSocketError] = [
            .socketCreationFailed,
            .bindFailed,
            .listenFailed,
            .connectionFailed,
            .notConnected,
            .sendFailed,
            .alreadyConnected,
            .alreadyClosed
        ]
        #expect(errors.count == 8)
    }

    @Test("Client fails without server")
    func clientFailsWithoutServer() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"

        let client = UnixSocketTransport(path: testPath)

        // NIO throws IOError when connecting to non-existent socket
        await #expect(throws: (any Error).self) {
            try await client.start()
        }
    }
}

// MARK: - Unix Socket Communication Tests

@Suite("Unix Socket Communication")
struct UnixSocketCommunicationTests {

    @Test("Client connects to server")
    func clientConnectsToServer() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketServer(path: testPath)
        try await server.start()

        let client = UnixSocketTransport(path: testPath)
        try await client.start()

        // If we got here, connection succeeded
        await client.stop()
        await server.stop()
    }

    @Test("Message from client to server")
    func clientToServerMessage() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketServer(path: testPath)
        try await server.start()

        let client = UnixSocketTransport(path: testPath)
        try await client.start()

        // Wait for connection - no sleep, direct await on stream
        let connection = try await awaitFirst(from: server.connections, timeout: .seconds(5))

        // Send from client
        let invocation = InvocationEnvelope(
            recipientID: "server",
            senderID: "client",
            target: "test",
            arguments: Data("hello".utf8)
        )
        try await client.send(.invocation(invocation))

        // Wait for message - no sleep, direct await on stream
        let envelope = try await awaitFirst(from: connection.messages, timeout: .seconds(5))

        if case .invocation(let inv) = envelope {
            #expect(inv.senderID == "client")
            #expect(inv.target == "test")
        } else {
            Issue.record("Expected invocation, got \(envelope)")
        }

        await client.stop()
        await server.stop()
    }

    @Test("Message from server to client")
    func serverToClientMessage() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketServer(path: testPath)
        try await server.start()

        let client = UnixSocketTransport(path: testPath)
        try await client.start()

        // Wait for connection
        let connection = try await awaitFirst(from: server.connections, timeout: .seconds(5))

        // Send from server
        let response = ResponseEnvelope(
            callID: "call-123",
            result: .success(Data("response".utf8))
        )
        try await connection.send(.response(response))

        // Wait for message on client
        let envelope = try await awaitFirst(from: client.messages, timeout: .seconds(5))

        if case .response(let resp) = envelope {
            #expect(resp.callID == "call-123")
        } else {
            Issue.record("Expected response, got \(envelope)")
        }

        await client.stop()
        await server.stop()
    }

    @Test("Bidirectional communication")
    func bidirectionalCommunication() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketServer(path: testPath)
        try await server.start()

        let client = UnixSocketTransport(path: testPath)
        try await client.start()

        // Wait for connection
        let connection = try await awaitFirst(from: server.connections, timeout: .seconds(5))

        // Run both directions concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Client → Server
            group.addTask {
                let request = InvocationEnvelope(
                    recipientID: "server",
                    senderID: "client",
                    target: "ping",
                    arguments: Data()
                )
                try await client.send(.invocation(request))
            }

            // Server → Client
            group.addTask {
                let response = ResponseEnvelope(
                    callID: "pong",
                    result: .success(Data())
                )
                try await connection.send(.response(response))
            }

            // Wait for both sends to complete
            try await group.waitForAll()
        }

        // Verify both sides received messages
        async let serverMsg = awaitFirst(from: connection.messages, timeout: .seconds(5))
        async let clientMsg = awaitFirst(from: client.messages, timeout: .seconds(5))

        let (sMsg, cMsg) = try await (serverMsg, clientMsg)

        // Verify we received the expected message types
        if case .invocation = sMsg {
            // Server received invocation from client
        } else {
            Issue.record("Expected invocation on server side")
        }

        if case .response = cMsg {
            // Client received response from server
        } else {
            Issue.record("Expected response on client side")
        }

        await client.stop()
        await server.stop()
    }

    @Test("Multiple messages")
    func multipleMessages() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketServer(path: testPath)
        try await server.start()

        let client = UnixSocketTransport(path: testPath)
        try await client.start()

        // Wait for connection
        let connection = try await awaitFirst(from: server.connections, timeout: .seconds(5))

        // Send 3 messages
        for i in 0..<3 {
            let invocation = InvocationEnvelope(
                recipientID: "server",
                senderID: "client",
                target: "message-\(i)",
                arguments: Data()
            )
            try await client.send(.invocation(invocation))
        }

        // Receive 3 messages with timeout
        let receivedCount = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                var count = 0
                for try await _ in connection.messages {
                    count += 1
                    if count >= 3 { break }
                }
                return count
            }

            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw TestError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        #expect(receivedCount == 3)

        await client.stop()
        await server.stop()
    }
}
