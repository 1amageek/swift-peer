// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-peer",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "Peer", targets: ["Peer"]),
        .library(name: "PeerGRPC", targets: ["PeerGRPC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-actor-runtime.git", from: "0.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.2.1"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.4.0"),
    ],
    targets: [
        // Core module - protocols and types
        .target(
            name: "Peer",
            dependencies: [
                .product(name: "ActorRuntime", package: "swift-actor-runtime"),
            ]
        ),
        // gRPC transport implementation
        .target(
            name: "PeerGRPC",
            dependencies: [
                "Peer",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            ]
        ),
        .testTarget(
            name: "PeerTests",
            dependencies: ["Peer"]
        ),
        .testTarget(
            name: "PeerGRPCTests",
            dependencies: ["PeerGRPC"]
        ),
    ]
)
