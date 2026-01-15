import Testing
import Foundation
@testable import Peer

@Suite("Peer Core Types")
struct PeerCoreTests {

    @Test("PeerID can be created and compared")
    func peerIDCreation() {
        let id1 = PeerID(name: "test-peer", host: "localhost", port: 50051)
        let id2 = PeerID(name: "test-peer", host: "localhost", port: 50051)
        let id3 = PeerID(name: "other-peer", host: "localhost", port: 50051)

        #expect(id1 == id2)
        #expect(id1 != id3)
        #expect(id1.name == "test-peer")
        #expect(id1.host == "localhost")
        #expect(id1.port == 50051)
        #expect(id1.value == "test-peer@localhost:50051")
    }

    @Test("PeerID supports string literal initialization")
    func peerIDStringLiteral() {
        let id: PeerID = "literal-peer@192.168.1.1:8080"
        #expect(id.name == "literal-peer")
        #expect(id.host == "192.168.1.1")
        #expect(id.port == 8080)
        #expect(id.value == "literal-peer@192.168.1.1:8080")
    }

    @Test("PeerID can be parsed from string")
    func peerIDParsing() {
        // Valid format - use init?(_:) failable initializer
        let validString = "alice@10.0.0.1:50051"
        let id = PeerID.init(validString)
        #expect(id != nil)
        #expect(id?.name == "alice")
        #expect(id?.host == "10.0.0.1")
        #expect(id?.port == 50051)

        // Invalid formats return nil (failable init)
        let invalidStrings = ["invalid", "missing@port", "@host:8080"]
        for str in invalidStrings {
            #expect(PeerID.init(str) == nil, "Expected nil for: \(str)")
        }
    }

    @Test("PeerID broadcast")
    func peerIDBroadcast() {
        let broadcast = PeerID.broadcast
        #expect(broadcast.isBroadcast)
        let regular = PeerID(name: "regular", host: "localhost", port: 8080)
        #expect(!regular.isBroadcast)
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
        let peerID = PeerID(name: "test", host: "localhost", port: 50051)
        let info = PeerInfo(peerID: peerID, displayName: "Test Peer")
        #expect(info.peerID.name == "test")
        #expect(info.peerID.value == "test@localhost:50051")
        #expect(info.displayName == "Test Peer")
    }

    @Test("PeerInfo with default display name")
    func peerInfoDefaultName() {
        let peerID = PeerID(name: "my-peer", host: "localhost", port: 8080)
        let info = PeerInfo(peerID: peerID)
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
        let peerID = PeerID(name: "discovered", host: "10.0.0.1", port: 50051)
        let peer = DiscoveredPeer(
            peerID: peerID,
            name: "Discovered Peer",
            endpoint: Endpoint(host: "10.0.0.1", port: 50051),
            metadata: ["key": "value"]
        )

        #expect(peer.peerID.name == "discovered")
        #expect(peer.peerID.value == "discovered@10.0.0.1:50051")
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
        let peerID = PeerID(name: "peer", host: "localhost", port: 8080)
        let started = TransportEvent.started
        let stopped = TransportEvent.stopped
        let connected = TransportEvent.peerConnected(peerID)
        let disconnected = TransportEvent.peerDisconnected(peerID)
        let received = TransportEvent.dataReceived(from: peerID, data: Data())
        let error = TransportEvent.error(.timeout)

        // Just verify they can be created
        _ = [started, stopped, connected, disconnected, received, error]
    }

    @Test("TransportError cases exist")
    func transportErrorCases() {
        let peerID = PeerID(name: "peer", host: "localhost", port: 8080)
        let notStarted = TransportError.notStarted
        let alreadyStarted = TransportError.alreadyStarted
        let connectionFailed = TransportError.connectionFailed(peerID, "reason")
        let sendFailed = TransportError.sendFailed(peerID, "reason")
        let closed = TransportError.connectionClosed
        let timeout = TransportError.timeout
        let notConnected = TransportError.notConnected(peerID)
        let invalid = TransportError.invalidData("reason")

        _ = [notStarted, alreadyStarted, connectionFailed, sendFailed, closed, timeout, notConnected, invalid]
    }
}

@Suite("Discovery Protocol")
struct DiscoveryProtocolTests {

    @Test("DiscoveryEvent cases exist")
    func discoveryEventCases() {
        let peerID = PeerID(name: "peer", host: "localhost", port: 8080)
        let appeared = DiscoveryEvent.peerAppeared(DiscoveredPeer(
            peerID: peerID,
            name: "Peer",
            endpoint: Endpoint(host: "localhost", port: 8080)
        ))
        let disappeared = DiscoveryEvent.peerDisappeared(peerID)
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
