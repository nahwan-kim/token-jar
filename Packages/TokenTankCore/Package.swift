// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TokenTankCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenTankDomain", targets: ["TokenTankDomain"]),
        .library(name: "TokenTankCore", targets: ["TokenTankCore"]),
        .library(name: "CodexProvider", targets: ["CodexProvider"]),
        .library(name: "ClaudeProvider", targets: ["ClaudeProvider"]),
        .library(name: "GrokProvider", targets: ["GrokProvider"]),
        .library(name: "CursorProvider", targets: ["CursorProvider"]),
        .library(name: "DoubaoProvider", targets: ["DoubaoProvider"]),
        .library(name: "TokenTankProviders", targets: ["TokenTankProviders"]),
    ],
    targets: [
        .target(name: "TokenTankDomain"),
        .target(
            name: "TokenTankCore",
            dependencies: ["TokenTankDomain"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(name: "CodexProvider", dependencies: ["TokenTankDomain", "TokenTankCore"]),
        .target(name: "ClaudeProvider", dependencies: ["TokenTankDomain", "TokenTankCore"]),
        .target(name: "GrokProvider", dependencies: ["TokenTankDomain", "TokenTankCore"]),
        .target(name: "CursorProvider", dependencies: ["TokenTankDomain", "TokenTankCore"]),
        .target(name: "DoubaoProvider", dependencies: ["TokenTankDomain", "TokenTankCore"]),
        .target(
            name: "TokenTankProviders",
            dependencies: [
                "TokenTankDomain",
                "TokenTankCore",
                "CodexProvider",
                "ClaudeProvider",
                "GrokProvider",
                "CursorProvider",
                "DoubaoProvider",
            ]
        ),
        .target(
            name: "TokenTankTestSupport",
            dependencies: ["TokenTankCore", "TokenTankDomain"],
            path: "Tests/Support"
        ),
        .testTarget(name: "TokenTankDomainTests", dependencies: ["TokenTankDomain"]),
        .testTarget(name: "TokenTankCoreTests", dependencies: ["TokenTankCore", "TokenTankDomain", "TokenTankTestSupport"]),
        .testTarget(name: "CodexProviderTests", dependencies: ["CodexProvider", "TokenTankCore", "TokenTankDomain", "TokenTankTestSupport"]),
        .testTarget(name: "ClaudeProviderTests", dependencies: ["ClaudeProvider", "TokenTankCore", "TokenTankDomain", "TokenTankTestSupport"]),
        .testTarget(name: "GrokProviderTests", dependencies: ["GrokProvider", "TokenTankCore", "TokenTankDomain", "TokenTankTestSupport"]),
        .testTarget(name: "CursorProviderTests", dependencies: ["CursorProvider", "TokenTankCore", "TokenTankDomain", "TokenTankTestSupport"]),
        .testTarget(name: "DoubaoProviderTests", dependencies: ["DoubaoProvider", "TokenTankCore", "TokenTankDomain", "TokenTankTestSupport"]),
        .testTarget(name: "TokenTankProvidersTests", dependencies: ["TokenTankProviders", "TokenTankCore", "TokenTankDomain", "TokenTankTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
