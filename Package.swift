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
        .library(name: "PeerSocket", targets: ["PeerSocket"]),
        .library(name: "PeerGRPC", targets: ["PeerGRPC"]),
        .library(name: "PeerMesh", targets: ["PeerMesh"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-actor-runtime.git", from: "0.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.2.1"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.78.0"),
    ],
    targets: [
        // Core module - protocols and types
        .target(
            name: "Peer",
            dependencies: [
                .product(name: "ActorRuntime", package: "swift-actor-runtime"),
            ]
        ),
        // Unix socket transport implementation
        .target(
            name: "PeerSocket",
            dependencies: [
                "Peer",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
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
        // P2P mesh transport (composite: local + remote)
        .target(
            name: "PeerMesh",
            dependencies: [
                "Peer",
            ]
        ),
        .testTarget(
            name: "PeerTests",
            dependencies: ["Peer"]
        ),
        .testTarget(
            name: "PeerSocketTests",
            dependencies: ["PeerSocket"]
        ),
        .testTarget(
            name: "PeerGRPCTests",
            dependencies: ["PeerGRPC"]
        ),
        .testTarget(
            name: "PeerMeshTests",
            dependencies: ["PeerMesh", "PeerSocket"]
        ),
    ]
)
