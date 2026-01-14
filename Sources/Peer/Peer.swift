// MARK: - Peer
// Swift Peer - Peer Communication Library
//
// A library providing protocols for peer discovery and communication.
// Re-exports ActorRuntime for distributed actor system integration.
//
// ## Modules
//
// - **Peer**: Core protocols and types (this module)
// - **PeerGRPC**: gRPC transport implementation
// - **PeerBLE**: BLE transport implementation (future)
// - **PeerBonjour**: Bonjour discovery implementation (future)
//
// ## Core Protocols
//
// - **Transport**: Send and receive data between peers
// - **PeerDiscovery**: Find peers on the network
//
// ## Core Types
//
// - **PeerID**: Identifies a peer
// - **PeerInfo**: Information about the local peer
// - **Endpoint**: Network address (host + port)
// - **DiscoveredPeer**: A peer found through discovery
// - **ServiceInfo**: Information for advertising a service
//
// ## ActorRuntime Integration
//
// This module re-exports ActorRuntime, providing:
// - **DistributedTransport**: Protocol for actor system transport
// - **InvocationEnvelope / ResponseEnvelope**: Codable RPC messages
// - **CodableInvocationEncoder / Decoder**: Serialization utilities
//
// ## Usage
//
// ```swift
// import Peer      // Includes ActorRuntime
// import PeerGRPC  // gRPC implementation
//
// let transport = GRPCTransport(...)
// let system = MyActorSystem(transport: transport)
// ```

@_exported import ActorRuntime

/// Peer library version.
public let PeerVersion = "1.0.0"

/// Peer protocol version.
public let PeerProtocolVersion: UInt8 = 1
