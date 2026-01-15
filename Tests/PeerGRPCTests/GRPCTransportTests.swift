import Testing
import Foundation
import Synchronization
@testable import PeerGRPC
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

private enum TestError: Error {
    case timeout
    case streamEnded
}

// MARK: - GRPCServer Tests

@Suite("GRPCServer Initialization")
struct GRPCServerInitTests {

    @Test("Server initialization")
    func serverInit() {
        let server = GRPCServer(configuration: .listen(port: 0))
        #expect(server.boundPort == nil)
    }
}

@Suite("GRPCServer Lifecycle")
struct GRPCServerLifecycleTests {

    @Test("Server start and stop")
    func serverStartStop() async throws {
        let server = GRPCServer(configuration: .listen(host: "127.0.0.1", port: 0))
        try await server.start()

        #expect(server.boundPort != nil)

        await server.stop()
    }
}

// MARK: - GRPCTransport Tests

@Suite("GRPCTransport Initialization")
struct GRPCTransportInitTests {

    @Test("Client initialization")
    func clientInit() {
        let transport = GRPCTransport(configuration: .connect(host: "127.0.0.1", port: 50051))
        // Just verify it can be created
        _ = transport
    }
}

// MARK: - GRPC Communication Tests

@Suite("GRPC Communication")
struct GRPCCommunicationTests {

    @Test("Client connects to server")
    func clientConnectsToServer() async throws {
        let server = GRPCServer(configuration: .listen(host: "127.0.0.1", port: 0))
        try await server.start()
        let serverPort = server.boundPort!

        let client = GRPCTransport(configuration: .connect(host: "127.0.0.1", port: serverPort))
        try await client.start()

        // If we got here, connection succeeded
        await client.stop()
        await server.stop()
    }

    @Test("Message from client to server")
    func clientToServerMessage() async throws {
        let server = GRPCServer(configuration: .listen(host: "127.0.0.1", port: 0))
        try await server.start()
        let serverPort = server.boundPort!

        let client = GRPCTransport(configuration: .connect(host: "127.0.0.1", port: serverPort))
        try await client.start()

        // Wait for connection on server side
        let connection = try await awaitFirst(from: server.connections, timeout: .seconds(5))

        // Send from client
        let invocation = InvocationEnvelope(
            recipientID: "server",
            senderID: "client",
            target: "test",
            arguments: Data("hello".utf8)
        )
        try await client.send(.invocation(invocation))

        // Wait for message on server
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
        let server = GRPCServer(configuration: .listen(host: "127.0.0.1", port: 0))
        try await server.start()
        let serverPort = server.boundPort!

        let client = GRPCTransport(configuration: .connect(host: "127.0.0.1", port: serverPort))
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
        let server = GRPCServer(configuration: .listen(host: "127.0.0.1", port: 0))
        try await server.start()
        let serverPort = server.boundPort!

        let client = GRPCTransport(configuration: .connect(host: "127.0.0.1", port: serverPort))
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

    @Test("Void response")
    func testVoidResponse() async throws {
        let server = GRPCServer(configuration: .listen(host: "127.0.0.1", port: 0))
        try await server.start()
        let serverPort = server.boundPort!

        // Start processing incoming messages on server
        let serverTask = Task {
            for try await connection in server.connections {
                Task {
                    for try await envelope in connection.messages {
                        if case .invocation(let invocation) = envelope {
                            let response = ResponseEnvelope(
                                callID: invocation.callID,
                                result: .void
                            )
                            try await connection.send(.response(response))
                        }
                    }
                }
            }
        }

        let client = GRPCTransport(configuration: .connect(host: "127.0.0.1", port: serverPort))
        try await client.start()

        let invocation = InvocationEnvelope(
            recipientID: "test-actor",
            senderID: "client",
            target: "voidMethod",
            arguments: Data()
        )

        try await client.send(.invocation(invocation))

        // Wait for response
        let envelope = try await awaitFirst(from: client.messages, timeout: .seconds(5))

        if case .response(let response) = envelope {
            #expect(response.callID == invocation.callID)
            #expect(response.result == .void)
        } else {
            Issue.record("Expected response, got \(envelope)")
        }

        serverTask.cancel()
        await client.stop()
        await server.stop()
    }
}
