# swift-peer

P2P networking library for [swift-actor-runtime](https://github.com/1amageek/swift-actor-runtime)'s distributed actor system.

## Features

- **PeerNode**: High-level P2P abstraction with automatic port handling
- **Transport-agnostic**: Core protocols support any transport (gRPC, BLE, WebSocket, etc.)
- **Mesh topology**: Any peer can invoke methods on any other peer
- **Swift 6 concurrency**: Built with modern Swift concurrency features
- **Discovery**: mDNS/Bonjour support for local network peer discovery

## Requirements

- Swift 6.2+
- macOS 26+, iOS 18+, tvOS 18+, watchOS 11+, visionOS 2+

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-peer.git", from: "1.0.0"),
]
```

### For Applications (Recommended)

Use **PeerNode** for high-level P2P networking:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "PeerNode", package: "swift-peer"),
    ]
)
```

### For Low-Level Access

Use **PeerGRPC** directly (not recommended for applications):

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "Peer", package: "swift-peer"),
        .product(name: "PeerGRPC", package: "swift-peer"),
    ]
)
```

## Modules

### PeerNode (Recommended)

High-level P2P abstraction for applications. Handles:
- Automatic port binding and fallback
- Connection management
- Peer discovery (mDNS)
- Transport routing

### Peer

Core protocols and types for peer communication.

- **DistributedTransport**: Protocol for sending/receiving messages
- **PeerID**: Peer identifier (`name@host:port`)
- **Re-exports ActorRuntime**: `InvocationEnvelope`, `ResponseEnvelope`, etc.

### PeerGRPC

gRPC implementation of `DistributedTransport`. Internal use only.

## Usage

### PeerNode (Recommended)

```swift
import PeerNode

// Create and start a node
let node = PeerNode(name: "alice", host: "127.0.0.1", port: 50051)
try await node.start()

print("Listening on port \(node.boundPort!)")
print("My PeerID: \(node.localPeerID)")

// Connect to another peer
let bob = PeerID(name: "bob", host: "192.168.1.100", port: 50051)
try await node.connect(to: bob)

// Handle incoming connections
Task {
    for await connection in node.incomingConnections {
        print("New connection from: \(connection.peerID)")
        // Use connection.transport for messaging
    }
}

// Get transport for a connected peer
if let transport = node.transport(for: bob) {
    // Send messages via transport
}

// Stop when done
await node.stop()
```

### Automatic Port Handling

```swift
// Port 0 = OS assigns available port
let node = PeerNode(name: "alice", port: 0)
try await node.start()
print("Bound to port: \(node.boundPort!)")  // e.g., 52341
```

### Peer Discovery (mDNS)

```swift
// Advertise on local network
try await node.advertise(metadata: ["version": "1.0"])

// Discover peers
let discovered = await node.discover(timeout: .seconds(5))
for try await peer in discovered {
    print("Found: \(peer.name) at \(peer.peerID)")
    try await node.connect(to: peer.peerID)
}

// Stop advertising
await node.stopAdvertising()
```

### Low-Level: GRPCTransport (Not Recommended)

For advanced use cases only:

```swift
import Peer
import PeerGRPC

// Server mode
let server = GRPCServer(configuration: .listen(host: "127.0.0.1", port: 50051))
try await server.start()

// Client mode
let transport = GRPCTransport(configuration: .connect(
    host: "192.168.1.100",
    port: 50051,
    peerID: myPeerID
))
try await transport.start()
```

## Architecture

### Module Dependency

```
                ActorRuntime
                     ↑
                   Peer (protocols, PeerID)
                     ↑
         ┌──────────┼──────────┐
         ↓          ↓          ↓
    PeerGRPC   PeerSocket   PeerMesh
         ↓          ↓          ↓
         └──────────┼──────────┘
                    ↓
              PeerNode [High-level API]
                    ↑
            Application Layer
```

**Important**: Applications should only import `PeerNode`.

### Mesh Topology

In a mesh network, every node acts as both caller and receiver:

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│  PeerNode A │◄───────►│  PeerNode B │◄───────►│  PeerNode C │
│  (:50051)   │         │  (:50052)   │         │  (:50053)   │
└─────────────┘         └─────────────┘         └─────────────┘
       ▲                                               ▲
       │                                               │
       └───────────────────────────────────────────────┘
```

### Communication Flow

1. **Caller**: `distributed actor` → `remoteCall()` → `InvocationEnvelope` → `Transport.sendInvocation()`
2. **Network**: Envelope sent via gRPC
3. **Receiver**: `incomingInvocations` → actor lookup → `executeDistributedTarget()` → `ResponseEnvelope`
4. **Caller**: Receives response, decodes result

### PeerID Format

```
name@host:port
│    │    │
│    │    └── Port number (e.g., 50051)
│    └─────── Host address (e.g., 127.0.0.1)
└──────────── Peer name (e.g., alice)

Example: alice@192.168.1.100:50051
```

The `address` property returns `host:port` for routing.

## Build & Test

```bash
# Build
swift build

# Run all tests
swift test

# Run specific test suite
swift test --filter PeerNodeTests
swift test --filter PeerGRPCTests
```

## Error Handling

PeerNode provides clear error messages:

```swift
public enum PeerNodeError: Error {
    case portUnavailable(port: Int)      // "Port 50051 is already in use"
    case startFailed(String)             // Startup failure
    case connectionFailed(peer: PeerID, reason: String)
    case notStarted                      // Node not started yet
    case alreadyStarted                  // Node already running
    case advertisingFailed(String)       // mDNS advertising failed
}
```

## Dependencies

- [swift-actor-runtime](https://github.com/1amageek/swift-actor-runtime) - Distributed Actor runtime
- [grpc-swift-2](https://github.com/grpc/grpc-swift-2) - gRPC core
- [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport) - HTTP/2 transport

## License

MIT
