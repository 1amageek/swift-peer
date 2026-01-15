import Testing
import Foundation
import Synchronization
@testable import PeerSocket
@testable import Peer

@Suite("UnixSocketTransport Initialization")
struct UnixSocketTransportInitTests {

    @Test("Server mode initialization")
    func serverModeInit() {
        let transport = UnixSocketTransport(mode: .server, path: "/tmp/test.sock")
        #expect(transport.socketPath == "/tmp/test.sock")
        #expect(transport.isServer == true)
    }

    @Test("Client mode initialization")
    func clientModeInit() {
        let transport = UnixSocketTransport(mode: .client, path: "/tmp/test.sock")
        #expect(transport.socketPath == "/tmp/test.sock")
        #expect(transport.isServer == false)
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
            .sendFailed
        ]
        #expect(errors.count == 6)
    }
}

@Suite("UnixSocketTransport Lifecycle")
struct UnixSocketTransportLifecycleTests {

    @Test("Server start and stop")
    func serverStartStop() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketTransport(mode: .server, path: testPath)
        try await server.start()

        // Verify socket file was created
        #expect(FileManager.default.fileExists(atPath: testPath))

        await server.stop()

        // Verify socket file was removed
        #expect(!FileManager.default.fileExists(atPath: testPath))
    }

    @Test("Client fails without server")
    func clientFailsWithoutServer() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"

        let client = UnixSocketTransport(mode: .client, path: testPath)

        // NIO throws IOError when connecting to non-existent socket
        await #expect(throws: (any Error).self) {
            try await client.start()
        }
    }
}

@Suite("UnixSocketTransport Communication")
struct UnixSocketTransportCommunicationTests {

    @Test("Client connects to server")
    func clientConnectsToServer() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketTransport(mode: .server, path: testPath)
        try await server.start()

        let client = UnixSocketTransport(mode: .client, path: testPath)
        try await client.start()

        // If we got here, connection succeeded
        await client.stop()
        await server.stop()
    }

    @Test("Message from client to server")
    func clientToServerMessage() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketTransport(mode: .server, path: testPath)
        try await server.start()

        let client = UnixSocketTransport(mode: .client, path: testPath)
        try await client.start()

        // Wait for connection to establish
        try await Task.sleep(for: .milliseconds(100))

        let received: Mutex<Envelope?> = Mutex(nil)
        let receiveTask = Task {
            for try await envelope in server.messages {
                received.withLock { $0 = envelope }
                break
            }
        }

        // Send from client
        let invocation = InvocationEnvelope(
            recipientID: "server",
            senderID: "client",
            target: "test",
            arguments: Data("hello".utf8)
        )
        try await client.send(.invocation(invocation))

        try await Task.sleep(for: .milliseconds(200))
        receiveTask.cancel()

        let msg = received.withLock { $0 }
        #expect(msg != nil)
        if case .invocation(let inv) = msg {
            #expect(inv.senderID == "client")
            #expect(inv.target == "test")
        }

        await client.stop()
        await server.stop()
    }

    @Test("Message from server to client")
    func serverToClientMessage() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketTransport(mode: .server, path: testPath)
        try await server.start()

        let client = UnixSocketTransport(mode: .client, path: testPath)
        try await client.start()

        // Wait for connection to establish
        try await Task.sleep(for: .milliseconds(100))

        let received: Mutex<Envelope?> = Mutex(nil)
        let receiveTask = Task {
            for try await envelope in client.messages {
                received.withLock { $0 = envelope }
                break
            }
        }

        // Send from server
        let response = ResponseEnvelope(
            callID: "call-123",
            result: .success(Data("response".utf8))
        )
        try await server.send(.response(response))

        try await Task.sleep(for: .milliseconds(200))
        receiveTask.cancel()

        let msg = received.withLock { $0 }
        #expect(msg != nil)
        if case .response(let resp) = msg {
            #expect(resp.callID == "call-123")
        }

        await client.stop()
        await server.stop()
    }

    @Test("Bidirectional communication")
    func bidirectionalCommunication() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketTransport(mode: .server, path: testPath)
        try await server.start()

        let client = UnixSocketTransport(mode: .client, path: testPath)
        try await client.start()

        try await Task.sleep(for: .milliseconds(100))

        let serverReceived: Mutex<Bool> = Mutex(false)
        let clientReceived: Mutex<Bool> = Mutex(false)

        let serverTask = Task {
            for try await _ in server.messages {
                serverReceived.withLock { $0 = true }
                break
            }
        }

        let clientTask = Task {
            for try await _ in client.messages {
                clientReceived.withLock { $0 = true }
                break
            }
        }

        // Client sends to server
        let request = InvocationEnvelope(
            recipientID: "server",
            senderID: "client",
            target: "ping",
            arguments: Data()
        )
        try await client.send(.invocation(request))

        // Server sends to client
        let response = ResponseEnvelope(
            callID: "pong",
            result: .success(Data())
        )
        try await server.send(.response(response))

        try await Task.sleep(for: .milliseconds(300))

        serverTask.cancel()
        clientTask.cancel()

        #expect(serverReceived.withLock { $0 })
        #expect(clientReceived.withLock { $0 })

        await client.stop()
        await server.stop()
    }

    @Test("Multiple messages")
    func multipleMessages() async throws {
        let testPath = "/tmp/unix-socket-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let server = UnixSocketTransport(mode: .server, path: testPath)
        try await server.start()

        let client = UnixSocketTransport(mode: .client, path: testPath)
        try await client.start()

        try await Task.sleep(for: .milliseconds(100))

        let messageCount: Mutex<Int> = Mutex(0)
        let receiveTask = Task {
            for try await _ in server.messages {
                let count = messageCount.withLock {
                    $0 += 1
                    return $0
                }
                if count >= 3 { break }
            }
        }

        // Send multiple messages
        for i in 0..<3 {
            let invocation = InvocationEnvelope(
                recipientID: "server",
                senderID: "client",
                target: "message-\(i)",
                arguments: Data()
            )
            try await client.send(.invocation(invocation))
        }

        try await Task.sleep(for: .milliseconds(300))
        receiveTask.cancel()

        #expect(messageCount.withLock { $0 } == 3)

        await client.stop()
        await server.stop()
    }
}
