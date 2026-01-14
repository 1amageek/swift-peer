import Testing
import Foundation
@testable import PeerGRPC
@testable import Peer

@Suite("GRPCTransport Tests")
struct GRPCTransportTests {

    @Test("Initialize transport with server configuration")
    func testInitialization() async throws {
        let transport = GRPCTransport(
            configuration: .server(port: 0)  // Use ephemeral port
        )

        #expect(transport.boundPort == nil)  // Not started yet
    }

    @Test("Open and close server transport")
    func testOpenClose() async throws {
        let transport = GRPCTransport(
            configuration: .server(port: 0)
        )

        try await transport.open()
        #expect(transport.boundPort != nil)

        try await transport.close()
    }

    @Test("Send invocation between client and server")
    func testInvocation() async throws {
        // Server transport
        let serverTransport = GRPCTransport(
            configuration: .server(host: "127.0.0.1", port: 0)
        )

        try await serverTransport.open()
        let serverPort = serverTransport.boundPort!

        // Start processing incoming invocations on server
        let serverTask = Task {
            for try await envelope in serverTransport.incomingInvocations {
                // Echo back the arguments as success response
                let response = ResponseEnvelope(
                    callID: envelope.callID,
                    result: .success(envelope.arguments)
                )
                try await serverTransport.sendResponse(response)
            }
        }

        // Client transport
        let clientTransport = GRPCTransport(
            configuration: .client(host: "127.0.0.1", port: serverPort)
        )

        try await clientTransport.open()

        // Send invocation
        let testData = "Hello, World!".data(using: .utf8)!
        let envelope = InvocationEnvelope(
            recipientID: "test-actor",
            target: "testMethod",
            arguments: testData
        )

        let response = try await clientTransport.sendInvocation(envelope)

        // Verify response
        if case .success(let data) = response.result {
            #expect(data == testData)
        } else {
            Issue.record("Expected success response")
        }

        // Cleanup
        serverTask.cancel()
        try await clientTransport.close()
        try await serverTransport.close()
    }

    @Test("Void response")
    func testVoidResponse() async throws {
        let serverTransport = GRPCTransport(
            configuration: .server(host: "127.0.0.1", port: 0)
        )

        try await serverTransport.open()
        let serverPort = serverTransport.boundPort!

        let serverTask = Task {
            for try await envelope in serverTransport.incomingInvocations {
                let response = ResponseEnvelope(
                    callID: envelope.callID,
                    result: .void
                )
                try await serverTransport.sendResponse(response)
            }
        }

        let clientTransport = GRPCTransport(
            configuration: .client(host: "127.0.0.1", port: serverPort)
        )

        try await clientTransport.open()

        let envelope = InvocationEnvelope(
            recipientID: "test-actor",
            target: "voidMethod",
            arguments: Data()
        )

        let response = try await clientTransport.sendInvocation(envelope)

        #expect(response.result == .void)

        serverTask.cancel()
        try await clientTransport.close()
        try await serverTransport.close()
    }
}
