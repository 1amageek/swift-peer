import Testing
import Foundation
@testable import Peer

@Suite("Peer Core Types")
struct PeerCoreTests {

    @Test("PeerID can be created and compared")
    func peerIDCreation() {
        let id1 = PeerID("test-peer")
        let id2 = PeerID("test-peer")
        let id3 = PeerID("other-peer")

        #expect(id1 == id2)
        #expect(id1 != id3)
        #expect(id1.value == "test-peer")
    }

    @Test("PeerID supports string literal initialization")
    func peerIDStringLiteral() {
        let id: PeerID = "literal-peer"
        #expect(id.value == "literal-peer")
    }

    @Test("PeerID broadcast")
    func peerIDBroadcast() {
        let broadcast = PeerID.broadcast
        #expect(broadcast.isBroadcast)
        #expect(!PeerID("regular").isBroadcast)
    }

    @Test("Endpoint can be created")
    func endpointCreation() {
        let endpoint = Endpoint(host: "192.168.1.1", port: 50051)
        #expect(endpoint.host == "192.168.1.1")
        #expect(endpoint.port == 50051)
        #expect(endpoint.description == "192.168.1.1:50051")
    }

    @Test("Endpoint equality")
    func endpointEquality() {
        let e1 = Endpoint(host: "localhost", port: 8080)
        let e2 = Endpoint(host: "localhost", port: 8080)
        let e3 = Endpoint(host: "localhost", port: 9090)

        #expect(e1 == e2)
        #expect(e1 != e3)
    }

    @Test("PeerInfo can be created")
    func peerInfoCreation() {
        let info = PeerInfo(peerID: PeerID("test"), displayName: "Test Peer")
        #expect(info.peerID.value == "test")
        #expect(info.displayName == "Test Peer")
    }

    @Test("PeerInfo with default display name")
    func peerInfoDefaultName() {
        let info = PeerInfo(peerID: PeerID("my-peer"))
        #expect(info.displayName == "my-peer")
    }

    @Test("ServiceInfo can be created")
    func serviceInfoCreation() {
        let info = ServiceInfo(
            name: "MyService",
            port: 50051,
            metadata: ["version": "1.0", "type": "test"]
        )

        #expect(info.name == "MyService")
        #expect(info.port == 50051)
        #expect(info.metadata["version"] == "1.0")
        #expect(info.metadata["type"] == "test")
    }

    @Test("ServiceInfo with empty metadata")
    func serviceInfoEmptyMetadata() {
        let info = ServiceInfo(name: "Simple", port: 8080)
        #expect(info.metadata.isEmpty)
    }

    @Test("DiscoveredPeer can be created")
    func discoveredPeerCreation() {
        let peer = DiscoveredPeer(
            peerID: PeerID("discovered"),
            name: "Discovered Peer",
            endpoint: Endpoint(host: "10.0.0.1", port: 50051),
            metadata: ["key": "value"]
        )

        #expect(peer.peerID.value == "discovered")
        #expect(peer.name == "Discovered Peer")
        #expect(peer.endpoint.host == "10.0.0.1")
        #expect(peer.endpoint.port == 50051)
        #expect(peer.metadata["key"] == "value")
    }
}

@Suite("Transport Protocol")
struct TransportProtocolTests {

    @Test("TransportEvent cases exist")
    func transportEventCases() {
        let started = TransportEvent.started
        let stopped = TransportEvent.stopped
        let connected = TransportEvent.peerConnected(PeerID("peer"))
        let disconnected = TransportEvent.peerDisconnected(PeerID("peer"))
        let received = TransportEvent.dataReceived(from: PeerID("peer"), data: Data())
        let error = TransportEvent.error(.timeout)

        // Just verify they can be created
        _ = [started, stopped, connected, disconnected, received, error]
    }

    @Test("TransportError cases exist")
    func transportErrorCases() {
        let notStarted = TransportError.notStarted
        let alreadyStarted = TransportError.alreadyStarted
        let connectionFailed = TransportError.connectionFailed(PeerID("peer"), "reason")
        let sendFailed = TransportError.sendFailed(PeerID("peer"), "reason")
        let closed = TransportError.connectionClosed
        let timeout = TransportError.timeout
        let notConnected = TransportError.notConnected(PeerID("peer"))
        let invalid = TransportError.invalidData("reason")

        _ = [notStarted, alreadyStarted, connectionFailed, sendFailed, closed, timeout, notConnected, invalid]
    }
}

@Suite("Discovery Protocol")
struct DiscoveryProtocolTests {

    @Test("DiscoveryEvent cases exist")
    func discoveryEventCases() {
        let appeared = DiscoveryEvent.peerAppeared(DiscoveredPeer(
            peerID: PeerID("peer"),
            name: "Peer",
            endpoint: Endpoint(host: "localhost", port: 8080)
        ))
        let disappeared = DiscoveryEvent.peerDisappeared(PeerID("peer"))
        let started = DiscoveryEvent.advertisingStarted
        let stopped = DiscoveryEvent.advertisingStopped
        let error = DiscoveryEvent.error(.timeout)

        _ = [appeared, disappeared, started, stopped, error]
    }

    @Test("DiscoveryError cases exist")
    func discoveryErrorCases() {
        let advertisingFailed = DiscoveryError.advertisingFailed("reason")
        let discoveryFailed = DiscoveryError.discoveryFailed("reason")
        let timeout = DiscoveryError.timeout
        let networkUnavailable = DiscoveryError.networkUnavailable
        let notSupported = DiscoveryError.notSupported

        _ = [advertisingFailed, discoveryFailed, timeout, networkUnavailable, notSupported]
    }
}
