# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build
swift build

# Run tests
swift test

# Run a specific test suite
swift test --filter PeerTests
swift test --filter PeerGRPCTests

# Run a single test
swift test --filter "GRPCTransportTests/testOpenClose"
```

## Architecture

swift-peer provides transport implementations for `swift-actor-runtime`'s distributed actor system.

### Modules

- **Peer**: Re-exports `ActorRuntime` (`DistributedTransport`, `InvocationEnvelope`, `ResponseEnvelope`, etc.) and provides discovery protocols.
- **PeerGRPC**: gRPC implementation of `DistributedTransport`.

### Dependencies

- `swift-actor-runtime` >= 0.3.1: Core distributed actor runtime
- `grpc-swift-2` >= 2.2.1: gRPC core
- `grpc-swift-nio-transport` >= 2.4.0: HTTP/2 transport

---

## Distributed Actor Communication Flow

This flow is **transport-agnostic** - same for gRPC, BLE, WebSocket, etc.

### Mesh Topology

In a mesh network, every node acts as both caller and receiver. There is no fixed "client" or "server" - any peer can invoke methods on any other peer.

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

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CALLER (any peer)                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  distributed actor ─► remoteCall() ─► InvocationEnvelope ─► Transport      │
│                                                                 │           │
│                                                                 ▼           │
│                                                         sendInvocation()    │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ Network (gRPC, BLE, WebSocket, etc.)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           RECEIVER (any peer)                               │
├─────────────────────────────────────────────────────────────────────────────┤
│  incomingInvocations ─► ActorRegistry.find() ─► executeDistributedTarget() │
│         │                                                     │             │
│         │                                                     ▼             │
│         │                                            ResultHandler          │
│         │                                                     │             │
│         │                                                     ▼             │
│         │◄─────────────────────────────────── ResponseEnvelope              │
│         │                                                                   │
│         ▼                                                                   │
│  sendResponse() ───────────────────────────────────────────────────────────►│
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ Network
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CALLER (any peer)                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  ResponseEnvelope ─► decode result ─► return to caller                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Detailed Flow

#### 1. Caller: Method Call → InvocationEnvelope

```swift
// User code: call a remote actor method
let result = try await remoteActor.someMethod(arg1, arg2)
```

ActorSystem's `remoteCall()`:
1. `CodableInvocationEncoder` serializes method name and arguments
2. Creates `InvocationEnvelope`:
   - `callID`: Unique ID for request/response matching
   - `recipientID`: Target actor ID
   - `target`: Method name (mangled Swift name)
   - `arguments`: Serialized arguments

#### 2. Caller: Transport.sendInvocation()

```swift
func sendInvocation(_ envelope: InvocationEnvelope) async throws -> ResponseEnvelope
```

Transport implementation (gRPC, BLE, etc.):
1. Serializes `InvocationEnvelope` to network format
2. Sends to target peer
3. Waits for and returns `ResponseEnvelope`

#### 3. Receiver: incomingInvocations Stream

```swift
var incomingInvocations: AsyncThrowingStream<InvocationEnvelope, Error> { get }
```

Transport implementation:
1. Receives request from network
2. Deserializes to `InvocationEnvelope`
3. Yields to stream
4. On error: `continuation.finish(throwing: error)`

#### 4. Receiver: Actor Lookup & Execution

```swift
for try await envelope in transport.incomingInvocations {
    // 1. Find actor
    guard let actor = registry.find(id: envelope.recipientID) else {
        // Send error response
        continue
    }

    // 2. Decode & execute
    let decoder = CodableInvocationDecoder(envelope: envelope)
    let handler = CodableResultHandler()

    try await executeDistributedTarget(
        on: actor,
        target: RemoteCallTarget(envelope.target),
        invocationDecoder: decoder,
        handler: handler
    )

    // 3. Send response
    let response = ResponseEnvelope(
        callID: envelope.callID,
        result: handler.result
    )
    try await transport.sendResponse(response)
}
```

#### 5. Receiver: Transport.sendResponse()

```swift
func sendResponse(_ envelope: ResponseEnvelope) async throws
```

Transport implementation:
1. Serializes `ResponseEnvelope`
2. Routes to caller using `callID`

#### 6. Caller: Response Handling

`sendInvocation()` returns `ResponseEnvelope`:
1. Matches with original request via `callID`
2. Decodes `InvocationResult`:
   - `.success(Data)`: Decode and return value
   - `.void`: Return Void
   - `.failure(RuntimeError)`: Throw error

---

## DistributedTransport Protocol

```swift
public protocol DistributedTransport: Sendable {
    /// Open the transport (establish connections, start server, etc.)
    func open() async throws

    /// Send an invocation and wait for response
    func sendInvocation(_ envelope: InvocationEnvelope) async throws -> ResponseEnvelope

    /// Stream of incoming invocations (can throw transport-level errors)
    var incomingInvocations: AsyncThrowingStream<InvocationEnvelope, Error> { get }

    /// Send a response to an invocation
    func sendResponse(_ envelope: ResponseEnvelope) async throws

    /// Close the transport and cleanup resources
    func close() async throws
}
```

### Why AsyncThrowingStream?

- Enables transport-level error notification (disconnection, deserialization failure, etc.)
- Consumer can handle errors with `for try await`

### Key Types

```swift
struct InvocationEnvelope: Codable, Sendable {
    let callID: String           // Request/response matching
    let recipientID: String      // Target actor ID
    let senderID: String?        // Sender actor ID (optional)
    let target: String           // Method name
    let genericSubstitutions: [String]
    let arguments: Data          // Serialized arguments
    let metadata: Metadata
}

struct ResponseEnvelope: Codable, Sendable {
    let callID: String           // Matches InvocationEnvelope.callID
    let result: InvocationResult
    let metadata: Metadata
}

enum InvocationResult: Codable, Sendable {
    case success(Data)           // Has return value
    case void                    // Void return
    case failure(RuntimeError)   // Error
}
```

---

## GRPCTransport Implementation

### Configuration Modes

```swift
// Server only: accepts incoming connections
let server = GRPCTransport(configuration: .server(port: 50051))

// Client only: connects to a remote server
let client = GRPCTransport(configuration: .client(host: "remote", port: 50051))

// Peer mode: both server and client (for mesh networks)
let peer = GRPCTransport(configuration: .peer(port: 50051))
```

### Lifecycle

```swift
let transport = GRPCTransport(configuration: .peer(port: 50051))

// Open the transport
try await transport.open()

// ... communication happens via sendInvocation/incomingInvocations ...

// Close when done
try await transport.close()
```

### Files

- `GRPCTransport.swift`: `DistributedTransport` implementation
- `GRPCTransportService.swift`: gRPC server handler
- `Messages.swift`: gRPC message types
- `Serialization.swift`: JSON serializer/deserializer

---

## Platform Requirements

- Swift 6.2+
- macOS 26+, iOS 18+, tvOS 18+, watchOS 11+, visionOS 2+

---

## grpc-swift-2 API Reference

### Dependencies

```swift
dependencies: [
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.2.1"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.4.0"),
]
```

### Imports

```swift
import GRPCCore
import GRPCNIOTransportHTTP2
// GRPCNIOTransportCore is re-exported by GRPCNIOTransportHTTP2
```

### Server Transport

```swift
// Server address uses GRPCNIOTransportCore.SocketAddress
// SocketAddress has static factory methods: .ipv4(host:port:), .ipv6(host:port:), .unixDomainSocket(path:)

let serverTransport = HTTP2ServerTransport.Posix(
    address: .ipv4(host: "127.0.0.1", port: 50051),
    transportSecurity: .plaintext
)

let server = GRPCServer(
    transport: serverTransport,
    services: [myService]
)

// Start server (runs until cancelled)
Task {
    try await server.serve()
}

// Get listening address (async throws)
guard let address = try await server.listeningAddress else {
    throw Error.serverBindFailed
}
```

### Client Transport

```swift
// Client target uses ResolvableTargets (different from SocketAddress)
// DEPRECATED: .ipv4(host:port:) → Use .ipv4(address:port:) instead

let clientTransport = try HTTP2ClientTransport.Posix(
    target: .ipv4(address: "127.0.0.1", port: 50051),  // ← "address" not "host"
    transportSecurity: .plaintext
)

let client = GRPCClient(transport: clientTransport)

// Run client connections (background task)
Task {
    try await client.runConnections()
}
```

### Key Differences

| Component | Server | Client |
|-----------|--------|--------|
| Type | `HTTP2ServerTransport.Posix` | `HTTP2ClientTransport.Posix` |
| Address param | `address: SocketAddress` | `target: ResolvableTarget` |
| IPv4 factory | `.ipv4(host:port:)` | `.ipv4(address:port:)` ← renamed |
| Init throws | No | Yes (`try`) |
| Run method | `serve()` | `runConnections()` |
| Get address | `listeningAddress` (async throws) | N/A |
