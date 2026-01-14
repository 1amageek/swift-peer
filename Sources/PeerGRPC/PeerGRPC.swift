// MARK: - PeerGRPC
// gRPC Transport Implementation for swift-peer
//
// This module provides a gRPC-based transport implementation that conforms
// to the Peer.Transport protocol. It uses GRPCCore directly without proto files.
//
// ## Features
//
// - No proto files required
// - JSON-based message serialization
// - Automatic peer discovery and connection management
// - Bidirectional communication
//
// ## Usage
//
// ```swift
// import Peer
// import PeerGRPC
//
// let transport = GRPCTransport(
//     localPeerInfo: .init(peerID: PeerID("my-node")),
//     configuration: .init(host: "0.0.0.0", port: 50051)
// )
//
// try await transport.start()
// ```
//
// ## Platform Support
//
// - macOS 26+
// - iOS 18+
// - Linux (with Swift 6.2+)

@_exported import Peer
