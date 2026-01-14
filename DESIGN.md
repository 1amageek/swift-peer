# swift-peer 設計ドキュメント

## 目的

swift-peerは、ピア間通信のための抽象化レイヤーを提供するSwiftライブラリです。特定のトランスポート技術（gRPC、BLE、WebSocketなど）に依存せず、統一されたインターフェースでピアの発見と通信を実現します。

swift-actor-runtimeをre-exportすることで、分散アクターシステムの構築に必要な全ての機能を単一のインポートで利用可能にします。

## 設計思想

### 1. 統合されたインポート

```swift
import Peer  // これだけで全て使える

// ActorRuntimeの機能
let envelope: InvocationEnvelope = ...
let decoder: CodableInvocationDecoder = ...

// Peerの機能
let transport: Transport = ...
let discovery: PeerDiscovery = ...
```

### 2. トランスポート非依存

コアモジュール（`Peer`）は特定の通信技術に依存しません。プロトコル定義のみを提供し、具体的な実装はアドオンモジュールが担当します。

```
┌─────────────────────────────────────────────────────────────────┐
│  アプリケーション                                                 │
│                                                                 │
│  import Peer                                                    │
│  import PeerGRPC   // 必要に応じて                               │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Peer (コアモジュール)                                           │
│                                                                 │
│  @_exported import ActorRuntime                                 │
│                                                                 │
│  - Transport protocol                                           │
│  - PeerDiscovery protocol                                       │
│  - 共通型定義 (PeerID, Endpoint, etc.)                          │
└───────────────────────────┬─────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  PeerGRPC    │    │  PeerBLE     │    │  PeerBonjour │
│  (gRPC実装)  │    │  (BLE実装)   │    │  (Bonjour)   │
└──────────────┘    └──────────────┘    └──────────────┘
```

### 3. デバイス依存の分離

各トランスポート実装は異なるプラットフォーム要件を持ちます：

| モジュール | 依存 | 対応プラットフォーム |
|-----------|------|---------------------|
| Peer | ActorRuntime | 全プラットフォーム |
| PeerGRPC | grpc-swift-2, NIO | macOS, iOS, Linux |
| PeerBLE | CoreBluetooth | iOS, macOS, watchOS, tvOS |
| PeerBonjour | Network.framework | Apple platforms |

アドオン方式により、必要なモジュールのみを選択してインポートできます。

## コアプロトコル

### Transport Protocol

```swift
public protocol Transport: Sendable {
    var localPeerInfo: PeerInfo { get }

    func start() async throws
    func stop() async throws
    func send(to peerID: PeerID, data: Data, timeout: Duration) async throws -> Data

    var connectedPeers: [PeerID] { get async }
    var events: AsyncStream<TransportEvent> { get async }
}
```

- `Data`の送受信のみを責務とする
- シリアライゼーションは上位レイヤー（ActorRuntime）が担当
- 非同期/Sendable対応

### PeerDiscovery Protocol

```swift
public protocol PeerDiscovery: Sendable {
    func discover(timeout: Duration) async -> AsyncThrowingStream<DiscoveredPeer, Error>
    func advertise(info: ServiceInfo) async throws
    func stopAdvertising() async throws
    var events: AsyncStream<DiscoveryEvent> { get async }
}
```

- ピアの発見と広告を担当
- Transportとは独立して動作可能

## ActorRuntimeとの関係

swift-peerはswift-actor-runtimeをre-exportします：

```
┌─────────────────────────────────────────────────────────────────┐
│  swift-peer/Peer                                                │
│                                                                 │
│  @_exported import ActorRuntime                                 │
│                                                                 │
│  // ActorRuntimeから提供される機能                               │
│  - DistributedTransport protocol                                │
│  - InvocationEnvelope / ResponseEnvelope (Codable)              │
│  - CodableInvocationEncoder / Decoder                           │
│  - SerializationSystem                                          │
│                                                                 │
│  // Peerが提供する機能                                           │
│  - Transport protocol (低レベル Data送受信)                      │
│  - PeerDiscovery protocol                                       │
│  - PeerID, Endpoint, etc.                                       │
└─────────────────────────────────────────────────────────────────┘
```

### レイヤー構造

```
┌─────────────────────────────────────────────────────────────────┐
│  DistributedActorSystem                                         │
│  (アプリケーション実装)                                           │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  DistributedTransport (ActorRuntime)                            │
│  InvocationEnvelope ←→ ResponseEnvelope                         │
└───────────────────────────┬─────────────────────────────────────┘
                            │ wraps
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Transport (Peer)                                               │
│  Data ←→ Data                                                   │
└───────────────────────────┬─────────────────────────────────────┘
                            │ implemented by
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  GRPCTransport / BLETransport / etc.                            │
└─────────────────────────────────────────────────────────────────┘
```

## モジュール構成

```
swift-peer/
├── Package.swift
├── DESIGN.md
├── Sources/
│   ├── Peer/                           # コアモジュール
│   │   ├── Peer.swift                  # @_exported import ActorRuntime
│   │   ├── Core/
│   │   │   ├── PeerID.swift
│   │   │   ├── PeerInfo.swift
│   │   │   ├── Endpoint.swift
│   │   │   ├── DiscoveredPeer.swift
│   │   │   ├── ResolvedPeer.swift
│   │   │   └── ServiceInfo.swift
│   │   ├── Transport/
│   │   │   ├── Transport.swift
│   │   │   ├── TransportEvent.swift
│   │   │   └── TransportError.swift
│   │   └── Discovery/
│   │       ├── PeerDiscovery.swift
│   │       └── DiscoveryEvent.swift
│   │
│   ├── PeerGRPC/                       # gRPCトランスポート実装
│   │   ├── GRPCTransport.swift
│   │   └── GRPCConfiguration.swift
│   │
│   ├── PeerBLE/                        # BLEトランスポート実装
│   │   ├── BLETransport.swift
│   │   ├── BLECentral.swift
│   │   └── BLEPeripheral.swift
│   │
│   └── PeerBonjour/                    # Bonjour発見実装
│       └── BonjourDiscovery.swift
```

## Package.swift

```swift
let package = Package(
    name: "swift-peer",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "Peer", targets: ["Peer"]),
        .library(name: "PeerGRPC", targets: ["PeerGRPC"]),
        .library(name: "PeerBLE", targets: ["PeerBLE"]),
        .library(name: "PeerBonjour", targets: ["PeerBonjour"]),
    ],
    dependencies: [
        .package(path: "../swift-actor-runtime"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "Peer",
            dependencies: [
                .product(name: "ActorRuntime", package: "swift-actor-runtime"),
            ]
        ),
        .target(
            name: "PeerGRPC",
            dependencies: [
                "Peer",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            ]
        ),
        .target(name: "PeerBLE", dependencies: ["Peer"]),
        .target(name: "PeerBonjour", dependencies: ["Peer"]),
    ]
)
```

## 使用例

```swift
import Peer      // ActorRuntime + Peer コア
import PeerGRPC  // gRPC実装

// トランスポート作成
let transport = GRPCTransport(
    localPeerInfo: LocalPeerInfo(peerID: PeerID("node-1")),
    config: .init(host: "0.0.0.0", port: 50051)
)

// DistributedActorSystemで使用
let system = MyActorSystem(transport: transport)

distributed actor Greeter {
    typealias ActorSystem = MyActorSystem

    distributed func greet(name: String) -> String {
        "Hello, \(name)!"
    }
}
```

## 設計原則

1. **統合**: ActorRuntimeをre-exportし、単一インポートで全機能を提供
2. **分離**: デバイス依存の実装はアドオンモジュールとして分離
3. **抽象化**: Transport/PeerDiscoveryプロトコルで実装を抽象化
4. **Swiftネイティブ**: async/await、Sendable、Distributed Actorを活用
