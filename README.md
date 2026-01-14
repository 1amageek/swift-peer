# swift-peer

Transport implementations for [swift-actor-runtime](https://github.com/1amageek/swift-actor-runtime)'s distributed actor system.

## Features

- **Transport-agnostic architecture**: Core protocols support any transport (gRPC, BLE, WebSocket, etc.)
- **Mesh topology support**: Any peer can invoke methods on any other peer
- **Swift 6 concurrency**: Built with modern Swift concurrency features

## Requirements

- Swift 6.2+
- macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, visionOS 2+

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-peer.git", from: "1.0.0"),
]
```

Then add the target dependencies:

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

### Peer

Core protocols and types for peer communication.

- **Transport**: Protocol for sending/receiving data between peers
- **PeerDiscovery**: Protocol for finding peers on the network
- **Re-exports ActorRuntime**: `DistributedTransport`, `InvocationEnvelope`, `ResponseEnvelope`, etc.

### PeerGRPC

gRPC implementation of `DistributedTransport`.

## Usage

### GRPCTransport Configuration

```swift
import Peer
import PeerGRPC

// Server mode: accepts incoming invocations
let server = GRPCTransport(configuration: .server(port: 50051))

// Client mode: connects to a remote server
let client = GRPCTransport(configuration: .client(host: "192.168.1.100", port: 50051))

// Peer mode: both server and client (for mesh networks)
let peer = GRPCTransport(configuration: .peer(port: 50051))
```

### Basic Example

```swift
import Peer
import PeerGRPC

// Create and open the transport
let transport = GRPCTransport(configuration: .peer(port: 50051))
try await transport.open()

// Use with your actor system
let system = MyActorSystem(transport: transport)

// ... communication happens via the actor system ...

// Close when done
try await transport.close()
```

### Handling Incoming Invocations

```swift
// Process incoming invocations from other peers
for try await envelope in transport.incomingInvocations {
    // Find the target actor
    guard let actor = registry.find(id: envelope.recipientID) else {
        continue
    }

    // Execute the distributed method
    let decoder = CodableInvocationDecoder(envelope: envelope)
    let handler = CodableResultHandler()

    try await executeDistributedTarget(
        on: actor,
        target: RemoteCallTarget(envelope.target),
        invocationDecoder: decoder,
        handler: handler
    )

    // Send the response
    let response = ResponseEnvelope(
        callID: envelope.callID,
        result: handler.result
    )
    try await transport.sendResponse(response)
}
```

## Architecture

### Mesh Topology

In a mesh network, every node acts as both caller and receiver:

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Peer A    │◄───────►│   Peer B    │◄───────►│   Peer C    │
│  (Transport)│         │  (Transport)│         │  (Transport)│
└─────────────┘         └─────────────┘         └─────────────┘
       ▲                                               ▲
       │                                               │
       └───────────────────────────────────────────────┘
```

### Communication Flow

1. **Caller**: `distributed actor` → `remoteCall()` → `InvocationEnvelope` → `Transport.sendInvocation()`
2. **Network**: Envelope sent via gRPC (or other transport)
3. **Receiver**: `incomingInvocations` → actor lookup → `executeDistributedTarget()` → `ResponseEnvelope`
4. **Caller**: Receives response, decodes result

## Build & Test

```bash
# Build
swift build

# Run all tests
swift test

# Run specific test suite
swift test --filter PeerTests
swift test --filter PeerGRPCTests

# Run a single test
swift test --filter "GRPCTransportTests/testOpenClose"
```

## Dependencies

- [swift-actor-runtime](https://github.com/1amageek/swift-actor-runtime) >= 0.3.1
- [grpc-swift-2](https://github.com/grpc/grpc-swift-2) >= 2.2.1
- [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport) >= 2.4.0

## License

MIT
