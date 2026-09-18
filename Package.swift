// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BedrockHarbor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HarborDomain", targets: ["HarborDomain"]),
        .library(name: "HarborCompatibility", targets: ["HarborCompatibility"]),
        .library(name: "HarborPlatform", targets: ["HarborPlatform"]),
        .library(name: "HarborApplication", targets: ["HarborApplication"]),
        .library(name: "HarborGooglePlay", targets: ["HarborGooglePlay"]),
        .library(name: "HarborRuntime", targets: ["HarborRuntime"]),
        .library(name: "HarborFeatures", targets: ["HarborFeatures"]),
        .executable(name: "BedrockHarbor", targets: ["BedrockHarbor"]),
    ],
    dependencies: [
        // Path A: independent Harbor Play client — no FinskyKit.
        // See docs/DEPENDENCY_POLICY.md and session notes.
    ],
    targets: [
        .target(
            name: "HarborDomain",
            path: "Sources/HarborDomain"
        ),
        .target(
            name: "HarborCompatibility",
            dependencies: ["HarborDomain"],
            path: "Sources/HarborCompatibility"
        ),
        .target(
            name: "HarborPlatform",
            dependencies: ["HarborDomain"],
            path: "Sources/HarborPlatform"
        ),
        .target(
            name: "HarborApplication",
            dependencies: ["HarborDomain", "HarborCompatibility", "HarborPlatform"],
            path: "Sources/HarborApplication"
        ),
        .target(
            name: "HarborGooglePlay",
            dependencies: ["HarborDomain", "HarborPlatform"],
            path: "Sources/HarborGooglePlay"
        ),
        .target(
            name: "HarborRuntime",
            dependencies: ["HarborDomain", "HarborPlatform"],
            path: "Sources/HarborRuntime"
        ),
        .target(
            name: "HarborFeatures",
            dependencies: ["HarborDomain", "HarborApplication", "HarborGooglePlay"],
            path: "Sources/HarborFeatures"
        ),
        .executableTarget(
            name: "BedrockHarbor",
            dependencies: [
                "HarborDomain",
                "HarborApplication",
                "HarborFeatures",
                "HarborGooglePlay",
                "HarborPlatform",
                "HarborRuntime",
                "HarborCompatibility",
            ],
            path: "Sources/BedrockHarbor"
        ),
        .testTarget(
            name: "HarborDomainTests",
            dependencies: ["HarborDomain"],
            path: "Tests/HarborDomainTests"
        ),
        .testTarget(
            name: "HarborCompatibilityTests",
            dependencies: ["HarborCompatibility", "HarborDomain"],
            path: "Tests/HarborCompatibilityTests"
        ),
        .testTarget(
            name: "HarborApplicationTests",
            dependencies: ["HarborApplication", "HarborDomain", "HarborCompatibility", "HarborPlatform"],
            path: "Tests/HarborApplicationTests"
        ),
        .testTarget(
            name: "HarborRuntimeTests",
            dependencies: ["HarborRuntime", "HarborDomain"],
            path: "Tests/HarborRuntimeTests"
        ),
        .testTarget(
            name: "HarborPlatformTests",
            dependencies: ["HarborPlatform", "HarborDomain"],
            path: "Tests/HarborPlatformTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
