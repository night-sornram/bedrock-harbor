import Foundation
import HarborDomain
import HarborPlatform

/// Runtime acquisition, verification, layout assembly, and process supervision.
/// Does not link mcpelauncher libraries; qualified artifacts are external processes.
public struct ApprovalCatalog: Sendable {
    public var releases: [RuntimeRelease]

    public init(releases: [RuntimeRelease] = []) {
        self.releases = releases
    }

    /// Foundation catalog is empty on purpose: nothing is "approved" until gate evidence exists.
    public static let foundation = ApprovalCatalog(releases: [])

    public func release(id: String) -> RuntimeRelease? {
        releases.first { $0.id == id }
    }
}

public struct RuntimeArtifactVerifier: Sendable {
    public init() {}

    public func verifySHA256(fileURL: URL, expected: String) throws {
        let actual = try Hashing.sha256Hex(ofFile: fileURL)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw HarborError.integrityFailure(
                reason: "Runtime artifact hash mismatch"
            )
        }
    }

    /// Inspect Mach-O magic for ARM64 without executing the binary.
    public func inspectArchitecture(executableURL: URL) throws -> RuntimeRelease.Architecture {
        let handle = try FileHandle(forReadingFrom: executableURL)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 8)
        guard data.count >= 8 else {
            throw HarborError.invalidPackage(reason: "Executable too small to be Mach-O")
        }
        // Fat / thin magics (little-endian host reads as stored)
        let thin64LE: UInt32 = 0xfeedfacf
        let thin64BE: UInt32 = 0xcffaedfe
        let fatBE: UInt32 = 0xcafebabe
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        if magic == fatBE || magic == 0xbebafeca {
            return .universal
        }
        if magic == thin64LE || magic == thin64BE {
            // CPU type for ARM64 is 0x0100000c (CPU_TYPE_ARM64)
            let cpuType = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
            let swapped = cpuType.bigEndian
            if cpuType == 0x0100_000c || swapped == 0x0100_000c || cpuType == 0x0c00_0001 || swapped == 0x0c00_0001 {
                return .arm64
            }
            if cpuType == 0x0100_0007 || swapped == 0x0100_0007 {
                return .x86_64
            }
            throw HarborError.invalidPackage(reason: "Unsupported Mach-O CPU type")
        }
        throw HarborError.invalidPackage(reason: "Not a recognized Mach-O executable")
    }
}

public struct ProcessLaunchSupervisor: RuntimeLaunching, Sendable {
    public var executableResolver: @Sendable (LaunchPlan) -> Bool

    public init(executableResolver: @escaping @Sendable (LaunchPlan) -> Bool = { plan in
        FileManager.default.isExecutableFile(atPath: plan.executableURL.path)
    }) {
        self.executableResolver = executableResolver
    }

    public func prepareLaunchPlan(
        profile: Profile,
        installation: InstalledMinecraft,
        runtime: RuntimeInstallation
    ) async throws -> LaunchPlan {
        throw HarborError.feasibilityGateIncomplete(
            reason: "Launch plan assembly requires a qualified runtime layout descriptor for \(runtime.releaseID)"
        )
    }

    public func start(plan: LaunchPlan) async throws -> LaunchSession {
        guard FileManager.default.fileExists(atPath: plan.executableURL.path) else {
            throw HarborError.unsupportedRuntime(reason: "Executable missing")
        }
        guard executableResolver(plan) else {
            throw HarborError.unsupportedRuntime(reason: "Executable is not runnable")
        }
        // Foundation build does not spawn unqualified binaries.
        throw HarborError.feasibilityGateIncomplete(
            reason: "Process launch remains disabled until runtime qualification is recorded"
        )
    }

    public func events(sessionID: UUID) -> AsyncStream<LaunchSessionState> {
        AsyncStream { $0.finish() }
    }

    public func requestTermination(sessionID: UUID) async throws {}

    /// Execute a verified plan with Foundation Process. Never uses a shell string.
    public static func spawnProcess(plan: LaunchPlan) throws -> Process {
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectoryURL
        var env = ProcessInfo.processInfo.environment
        for (key, value) in plan.environment {
            env[key] = value
        }
        process.environment = env
        return process
    }
}

public actor InMemoryRuntimeProvider: RuntimeProviding {
    public var catalog: ApprovalCatalog
    public var installations: [RuntimeInstallation]

    public init(catalog: ApprovalCatalog = .foundation, installations: [RuntimeInstallation] = []) {
        self.catalog = catalog
        self.installations = installations
    }

    public func discoverInstallations() async throws -> [RuntimeInstallation] {
        installations
    }

    public func approvedReleases() async throws -> [RuntimeRelease] {
        catalog.releases
    }

    public func install(release: RuntimeRelease, artifactURL: URL) async throws -> RuntimeInstallation {
        guard catalog.release(id: release.id) != nil else {
            throw HarborError.unsupportedRuntime(reason: "Release is not in the approval catalog")
        }
        let verifier = RuntimeArtifactVerifier()
        try verifier.verifySHA256(fileURL: artifactURL, expected: release.artifactSHA256)
        let arch = try verifier.inspectArchitecture(executableURL: artifactURL)
        if arch != .arm64 && arch != .universal {
            throw HarborError.unsupportedRuntime(reason: "Runtime architecture \(arch.rawValue) is not supported")
        }
        let installation = RuntimeInstallation(
            releaseID: release.id,
            relativeInstallPath: "Runtimes/\(release.id)",
            artifactSHA256: release.artifactSHA256,
            health: .unknown,
            verificationNotes: ["Hash verified at install boundary"]
        )
        installations.append(installation)
        return installation
    }

    public func health(for installationID: UUID) async throws -> RuntimeHealth {
        installations.first { $0.id == installationID }?.health ?? .unknown
    }
}

// MARK: - Qualified candidate note (not approved)

public enum RuntimeCandidates {
    /// Observed upstream macOS release used only as a research candidate.
    /// Not approved until feasibility gate + provenance + layout descriptor exist.
    public static let macosBuilderV184_573 = RuntimeRelease(
        id: "mcpelauncher-macos-v1.8.4-573",
        displayName: "mcpelauncher macOS v1.8.4-573 (candidate)",
        upstreamReleaseTag: "v1.8.4-573",
        assetName: "TBD-inspect-actual-asset",
        artifactSHA256: "TO_BE_FILLED_AFTER_DOWNLOAD_VERIFICATION",
        architecture: .arm64,
        minimumOS: "14.0",
        layoutAdapterID: "mcpelauncher-macos-unqualified",
        capabilities: [],
        helperRequirements: ["bh-helpers-v1"],
        requiredPatchIDs: [],
        licenseNotices: ["See upstream release and component licenses"],
        sourceURLs: [
            "https://github.com/minecraft-linux/macos-builder/releases/tag/v1.8.4-573",
            "https://github.com/minecraft-linux/mcpelauncher-manifest",
        ],
        qualificationEvidence: "Not qualified. Candidate only as of 2026-09-18 research.",
        downloadURL: nil
    )
}
