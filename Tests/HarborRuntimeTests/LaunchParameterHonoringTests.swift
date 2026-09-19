import XCTest
import Foundation
import HarborDomain
import HarborPlatform
@testable import HarborRuntime

/// `ProcessLaunchSupervisor.prepareLaunchPlan` must honor the caller's installation
/// and runtime; discovery results are fallbacks only. XCTest (not Swift Testing) so
/// the static test seams here never race with the other XCTest suites that use them.
final class LaunchParameterHonoringTests: XCTestCase {
    private var tempDir: URL!
    private var supportRoot: URL!
    private var compatRoot: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchParamHonoringTests-\(UUID().uuidString)", isDirectory: true)
        supportRoot = tempDir.appendingPathComponent("Support", isDirectory: true)
        compatRoot = tempDir.appendingPathComponent("CompatibilityPatches", isDirectory: true)
        LocalRuntimeDiscovery.harborSupportOverride = supportRoot
        HarborCompatibilityPatches.harborRootOverride = compatRoot
        LocalRuntimeDiscovery.resetProcessDiscoveryCachesForTesting()
    }

    override func tearDown() {
        LocalRuntimeDiscovery.harborSupportOverride = nil
        HarborCompatibilityPatches.harborRootOverride = nil
        HarborCompatibilityPatches.catalogLoader = nil
        LocalRuntimeDiscovery.resetProcessDiscoveryCachesForTesting()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - fixtures

    @discardableResult
    private func makeUsableRuntimeRoot(name: String, executableBytes: Data) throws -> URL {
        let fm = FileManager.default
        let root = supportRoot.appendingPathComponent("Runtimes/\(name)", isDirectory: true)
        let macos = root.appendingPathComponent("MacOS", isDirectory: true)
        let platforms = root.appendingPathComponent("PlugIns/platforms", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: platforms, withIntermediateDirectories: true)
        let executable = macos.appendingPathComponent("mcpelauncher-client")
        try executableBytes.write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("# qt.conf".utf8).write(to: macos.appendingPathComponent("qt.conf"))
        try Data("fake dylib".utf8).write(to: platforms.appendingPathComponent("libqcocoa.dylib"))
        return root
    }

    /// Game installation under the Installations/ root with a real libminecraftpe.so.
    @discardableResult
    private func makeGameInstallation(name: String) throws -> URL {
        let fm = FileManager.default
        let game = supportRoot.appendingPathComponent("Installations/\(name)", isDirectory: true)
        let libDir = game.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        try Data("libminecraftpe-\(name)".utf8).write(to: libDir.appendingPathComponent("libminecraftpe.so"))
        return game
    }

    /// Valid compat install so `prepareForLaunchDetailed` is offline-instant.
    private func writeInstalledPatch(names: [String]) throws {
        let fm = FileManager.default
        let modDir = compatRoot
            .appendingPathComponent("1.26.45.1", isDirectory: true)
            .appendingPathComponent("arm64-v8a", isDirectory: true)
        try fm.createDirectory(at: modDir, withIntermediateDirectories: true)
        let mod = modDir.appendingPathComponent(HarborCompatibilityPatches.modLibraryName)
        try Data("fake-mod".utf8).write(to: mod)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mod.path)
        let meta = HarborCompatibilityPatches.Metadata(
            version: "1.26.45.1",
            assetURL: "https://example.com/asset.zip",
            installPath: modDir.path,
            supportedVersionCodes: [],
            supportedVersionNames: names,
            catalogCheckedAt: Date()
        )
        try JSONEncoder().encode(meta).write(to: compatRoot.appendingPathComponent("metadata.json"))
    }

    private func makePaths() -> HarborPaths {
        HarborPaths(
            applicationSupportRoot: tempDir.appendingPathComponent("Paths/Support", isDirectory: true),
            cachesRoot: tempDir.appendingPathComponent("Paths/Caches", isDirectory: true),
            logsRoot: tempDir.appendingPathComponent("Paths/Logs", isDirectory: true)
        )
    }

    private func makeInstallation(gameDir: URL, versionName: String) -> InstalledMinecraft {
        InstalledMinecraft(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: LocalRuntimeDiscovery.versionCode(fromVersionName: versionName),
                abi: .arm64v8a
            ),
            originalVersionName: versionName,
            relativeGameDirectory: gameDir.path,
            integrity: .verified,
            providerID: ProviderID(rawValue: "test")
        )
    }

    private func makeRuntime(root: URL, releaseID: String) -> RuntimeInstallation {
        RuntimeInstallation(
            releaseID: releaseID,
            relativeInstallPath: root.path,
            artifactSHA256: "unused",
            health: .healthy
        )
    }

    /// The `-dg` value of a launch plan (the game directory the launcher will use).
    private func gameDirectoryArgument(of plan: LaunchPlan) throws -> String {
        let index = try XCTUnwrap(plan.arguments.firstIndex(of: "-dg"))
        return plan.arguments[index + 1]
    }

    // MARK: - honoring the caller's installation

    func testPlanUsesCallerInstallationNotNewestDiscovery() async throws {
        try writeInstalledPatch(names: ["1.26.40.0", "1.26.50.0"])
        try makeUsableRuntimeRoot(name: "runtime", executableBytes: Data("exec".utf8))

        let older = try makeGameInstallation(name: "1.26.40.0")
        let newer = try makeGameInstallation(name: "1.26.50.0")
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: older.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: newer.path)

        // Sanity: discovery alone picks the NEWEST installation (paths resolve
        // /var → /private/var, so compare standardized).
        let discovered = try XCTUnwrap(LocalRuntimeDiscovery().discoverDefault())
        XCTAssertEqual(
            URL(fileURLWithPath: discovered.gameInstallation.relativeGameDirectory).standardizedFileURL.path,
            newer.standardizedFileURL.path
        )

        let supervisor = ProcessLaunchSupervisor(paths: makePaths())
        let callerInstallation = makeInstallation(gameDir: older, versionName: "1.26.40.0")
        let plan = try await supervisor.prepareLaunchPlan(
            profile: Profile(name: "Test"),
            installation: callerInstallation,
            runtime: makeRuntime(
                root: supportRoot.appendingPathComponent("Runtimes/runtime", isDirectory: true),
                releaseID: "harbor-test"
            )
        )

        // The profile's selected (older) installation wins over discovery's newest scan.
        XCTAssertEqual(try gameDirectoryArgument(of: plan), older.path)
        XCTAssertEqual(plan.installationID, callerInstallation.id)
    }

    // MARK: - honoring the caller's runtime

    func testPlanUsesCallerRuntimeRootWhenUsableAndDiscoveryWhenNot() async throws {
        try writeInstalledPatch(names: ["1.26.40.0"])
        // Two usable roots: discovery takes the first in listing order ("a-runtime"
        // on APFS); the caller pins the other one, so honoring is observable.
        _ = try makeUsableRuntimeRoot(name: "a-runtime", executableBytes: Data("exec-a".utf8))
        let pinnedRoot = try makeUsableRuntimeRoot(name: "z-runtime", executableBytes: Data("exec-z".utf8))
        let game = try makeGameInstallation(name: "1.26.40.0")

        let supervisor = ProcessLaunchSupervisor(paths: makePaths())
        let installation = makeInstallation(gameDir: game, versionName: "1.26.40.0")

        // Caller's usable runtime root wins over the first discovered root.
        let honored = try await supervisor.prepareLaunchPlan(
            profile: Profile(name: "Test"),
            installation: installation,
            runtime: makeRuntime(root: pinnedRoot, releaseID: "harbor-pinned")
        )
        XCTAssertEqual(
            honored.executableURL.path,
            pinnedRoot.appendingPathComponent("MacOS/mcpelauncher-client").path
        )

        // Discovery fallback: an unusable caller runtime falls back to the discovered root.
        let broken = supportRoot.appendingPathComponent("Runtimes/broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let fallback = try await supervisor.prepareLaunchPlan(
            profile: Profile(name: "Test"),
            installation: installation,
            runtime: makeRuntime(root: broken, releaseID: "harbor-broken")
        )
        let discoveredExecutable = try XCTUnwrap(
            LocalRuntimeDiscovery().discoverDefault()?.layout.executableURL
        )
        XCTAssertEqual(fallback.executableURL.path, discoveredExecutable.path)
        XCTAssertNotEqual(
            fallback.executableURL.path,
            broken.appendingPathComponent("MacOS/mcpelauncher-client").path,
            "an unusable caller runtime must never be used"
        )
    }

    func testCallerRuntimeWithSameReleaseIDAsDiscoveryStillUsesCallerRoot() async throws {
        try writeInstalledPatch(names: ["1.26.40.0"])
        // Two usable roots sharing the same runtime.json version: discovery's layout
        // gets registered under the SAME releaseID as the caller's runtime, but at a
        // different root. The registered layout must not hijack the caller's root.
        _ = try makeUsableRuntimeRoot(name: "a-runtime", executableBytes: Data("exec-a".utf8))
        let callerRoot = try makeUsableRuntimeRoot(name: "zz-caller", executableBytes: Data("exec-zz".utf8))
        for root in [
            supportRoot.appendingPathComponent("Runtimes/a-runtime", isDirectory: true),
            callerRoot,
        ] {
            try Data(#"{"version":"v9.9.9-1"}"#.utf8).write(to: root.appendingPathComponent("runtime.json"))
        }
        let game = try makeGameInstallation(name: "1.26.40.0")

        let supervisor = ProcessLaunchSupervisor(paths: makePaths())
        let plan = try await supervisor.prepareLaunchPlan(
            profile: Profile(name: "Test"),
            installation: makeInstallation(gameDir: game, versionName: "1.26.40.0"),
            runtime: makeRuntime(root: callerRoot, releaseID: "harbor-mcpelauncher-v9.9.9-1")
        )

        XCTAssertEqual(
            plan.executableURL.standardizedFileURL.path,
            callerRoot.appendingPathComponent("MacOS/mcpelauncher-client").standardizedFileURL.path,
            "a same-named releaseID must not let discovery's layout override the caller's runtime root"
        )
    }
}
