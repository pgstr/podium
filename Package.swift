// swift-tools-version: 6.2
import PackageDescription

// PodiumCore is pure logic (spec, compose translation, cron, parsing, diffing) —
// no Containerization import, no runtime side effects. It builds and tests on
// Linux, which is what CI uses (E1.1/E1.5).
//
// The `podium` executable and its Containerization dependency are macOS-only,
// so they are included conditionally: on Linux the package is just Core + tests.

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    // Control plane v2 (E3): gRPC over unix sockets. These add zero new pins —
    // all four were already in Package.resolved via containerization (macOS).
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.2"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.9.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
]
var packageTargets: [Target] = [
    .target(
        name: "PodiumCore",
        dependencies: [.product(name: "Yams", package: "Yams")],
        path: "Sources/PodiumCore"
    ),
    .testTarget(
        name: "PodiumCoreTests",
        dependencies: ["PodiumCore", .product(name: "Yams", package: "Yams")],
        path: "Tests/PodiumCoreTests"
    ),
    // PodiumDaemon (E2): runtime side — state store (E2.2) and the reconciler
    // (E2.3). The container runtime is abstracted behind `ContainerRuntime`
    // (Runtime.swift), so this target never imports Containerization: the
    // real adapter lives in the macOS-only `podium` executable, and the
    // reconciler + crash-injection tests run on Linux CI with a mock.
    .target(
        name: "PodiumDaemon",
        dependencies: ["PodiumCore"],
        path: "Sources/PodiumDaemon"
    ),
    .testTarget(
        name: "PodiumDaemonTests",
        dependencies: ["PodiumDaemon", "PodiumCore"],
        path: "Tests/PodiumDaemonTests"
    ),
    // PodiumRPC (E3): generated proto types (Sources/PodiumRPC/Generated/,
    // checked in — regenerate with `make proto`) + the PodiumControl service
    // implementation. Builds on both platforms; Linux CI exercises it via the
    // in-process transport (no unix socket needed for the service tests).
    .target(
        name: "PodiumRPC",
        dependencies: [
            "PodiumCore",
            "PodiumDaemon",
            .product(name: "GRPCCore", package: "grpc-swift-2"),
            .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        path: "Sources/PodiumRPC"
    ),
    .testTarget(
        name: "PodiumRPCTests",
        dependencies: [
            "PodiumRPC",
            .product(name: "GRPCInProcessTransport", package: "grpc-swift-2"),
        ],
        path: "Tests/PodiumRPCTests"
    ),
]

#if os(macOS)
packageDependencies.append(
    // vminit is pinned to this exact release in Sources/podium/main.swift.
    // Containerization only guarantees source stability within a minor line;
    // an exact pin prevents host/guest RPC skew on unattended installs.
    .package(url: "https://github.com/apple/containerization.git", exact: "0.46.0"))
packageTargets.append(
    .executableTarget(
        name: "podium",
        dependencies: [
            "PodiumCore",
            "PodiumDaemon",
            "PodiumRPC",
            .product(name: "Containerization", package: "containerization"),
            .product(name: "ContainerizationOS", package: "containerization"),
            .product(name: "ContainerizationArchive", package: "containerization"),
        ],
        path: "Sources/podium"
    ))
#endif

let package = Package(
    name: "podium",
    platforms: [.macOS("26.0")],
    dependencies: packageDependencies,
    targets: packageTargets
)
