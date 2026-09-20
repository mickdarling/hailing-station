// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Hail",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // Frame protocol shared by the terminal and the host daemon (#2). Foundation only, no dependencies.
        .library(name: "HailProtocol", targets: ["HailProtocol"]),
        // Terminal logic: protocols for every module (#3), implementations arrive per issue.
        .library(name: "HailCore", targets: ["HailCore"]),
        // Host daemon library (#10) and its executable.
        .library(name: "HailDaemonKit", targets: ["HailDaemonKit"]),
        .executable(name: "haild", targets: ["haild"]),
        // Canonical example frames plus the checked-in JSON copies as a resource bundle. Test targets and the
        // generator depend on it; the app and haild do not ship it (#2, #28).
        .library(name: "HailProtocolFixtures", targets: ["HailProtocolFixtures"]),
        // Writes fixtures/frames/*.json and the schema from HailProtocolFixtures; CI fails on drift (#28).
        .executable(name: "hail-protocol-gen", targets: ["hail-protocol-gen"]),
    ],
    targets: [
        .target(name: "HailProtocol", swiftSettings: strict),
        .target(
            name: "HailProtocolFixtures", dependencies: ["HailProtocol"],
            resources: [.copy("../../fixtures/frames"), .copy("../../fixtures/invalid")], swiftSettings: strict
        ),
        .testTarget(
            name: "HailProtocolTests", dependencies: ["HailProtocol", "HailProtocolFixtures"], swiftSettings: strict
        ),

        .target(name: "HailCore", dependencies: ["HailProtocol"], swiftSettings: strict),
        .testTarget(name: "HailCoreTests", dependencies: ["HailCore"], swiftSettings: strict),

        .target(name: "HailDaemonKit", dependencies: ["HailProtocol"], swiftSettings: strict),
        .testTarget(name: "HailDaemonKitTests", dependencies: ["HailDaemonKit"], swiftSettings: strict),
        .executableTarget(name: "haild", dependencies: ["HailDaemonKit"], swiftSettings: strict),
        .executableTarget(
            name: "hail-protocol-gen", dependencies: ["HailProtocol", "HailProtocolFixtures"], swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
