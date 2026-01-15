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

    @Test("Start and stop server transport")
    func testStartStop() async throws {
        let transport = GRPCTransport(
            configuration: .server(port: 0)
        )

        try await transport.start()
        #expect(transport.boundPort != nil)

        await transport.stop()
    }

    @Test("Bidirectional streaming between client and server")
    func testBidirectionalStreaming() async throws {
        // Server transport
        let serverTransport = GRPCTransport(
            configuration: .server(host: "127.0.0.1", port: 0)
        )

        try await serverTransport.start()
        let serverPort = serverTransport.boundPort!

        // Start processing incoming messages on server
        let serverTask = Task {
            for try await envelope in serverTransport.messages {
                switch envelope {
                case .invocation(let invocation):
                    // Echo back the arguments as success response
                    let response = ResponseEnvelope(
                        callID: invocation.callID,
                        result: .success(invocation.arguments)
                    )
                    try await serverTransport.send(.response(response))
                case .response:
                    // Server shouldn't receive responses in this test
                    break
                }
            }
        }

        // Client transport
        let clientTransport = GRPCTransport(
            configuration: .client(host: "127.0.0.1", port: serverPort)
        )

        try await clientTransport.start()

        // Create test invocation
        let testData = "Hello, World!".data(using: .utf8)!
        let invocation = InvocationEnvelope(
            recipientID: "test-actor",
            target: "testMethod",
            arguments: testData
        )

        // Send invocation
        try await clientTransport.send(.invocation(invocation))

        // Wait for response
        var receivedResponse: ResponseEnvelope?
        for try await envelope in clientTransport.messages {
            if case .response(let response) = envelope,
               response.callID == invocation.callID {
                receivedResponse = response
                break
            }
        }

        // Verify response
        #expect(receivedResponse != nil)
        if let response = receivedResponse,
           case .success(let data) = response.result {
            #expect(data == testData)
        } else {
            Issue.record("Expected success response with echoed data")
        }

        // Cleanup
        serverTask.cancel()
        await clientTransport.stop()
        await serverTransport.stop()
    }

    @Test("Void response")
    func testVoidResponse() async throws {
        let serverTransport = GRPCTransport(
            configuration: .server(host: "127.0.0.1", port: 0)
        )

        try await serverTransport.start()
        let serverPort = serverTransport.boundPort!

        let serverTask = Task {
            for try await envelope in serverTransport.messages {
                if case .invocation(let invocation) = envelope {
                    let response = ResponseEnvelope(
                        callID: invocation.callID,
                        result: .void
                    )
                    try await serverTransport.send(.response(response))
                }
            }
        }

        let clientTransport = GRPCTransport(
            configuration: .client(host: "127.0.0.1", port: serverPort)
        )

        try await clientTransport.start()

        let invocation = InvocationEnvelope(
            recipientID: "test-actor",
            target: "voidMethod",
            arguments: Data()
        )

        try await clientTransport.send(.invocation(invocation))

        // Wait for response
        var receivedResponse: ResponseEnvelope?
        for try await envelope in clientTransport.messages {
            if case .response(let response) = envelope,
               response.callID == invocation.callID {
                receivedResponse = response
                break
            }
        }

        #expect(receivedResponse?.result == .void)

        serverTask.cancel()
        await clientTransport.stop()
        await serverTransport.stop()
    }
}
