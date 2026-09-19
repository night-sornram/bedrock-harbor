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
        // Microsoft sign-in helper resources: the pre-launch readiness gate in
        // makePlan refuses roots without them.
        let webview = macos.appendingPathComponent("mcpelauncher-webview")
        try executableBytes.write(to: webview)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: webview.path)
        for rel in ["Resources/qml/QtQuick", "Resources/qml/QtWebEngine"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(rel, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
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

    // MARK: - launch timing spans plan preparation

    func testLaunchTimingRecordsPreparationAndPlanReadyStages() async throws {
        try writeInstalledPatch(names: ["1.26.40.0"])
        try makeUsableRuntimeRoot(name: "runtime", executableBytes: Data("exec".utf8))
        let game = try makeGameInstallation(name: "1.26.40.0")
        let paths = makePaths()
        let supervisor = ProcessLaunchSupervisor(paths: paths)

        // Real pipeline shape: the plan is prepared first (its compatibility
        // preparation must be timed), then a real process is launched through
        // the same supervisor, so the single persisted "launch" record must
        // carry BOTH preparation stages AND both process stages.
        _ = try await supervisor.prepareLaunchPlan(
            profile: Profile(name: "Timing"),
            installation: makeInstallation(gameDir: game, versionName: "1.26.40.0"),
            runtime: makeRuntime(
                root: supportRoot.appendingPathComponent("Runtimes/runtime", isDirectory: true),
                releaseID: "harbor-test"
            )
        )
        let session = try await supervisor.start(plan: LaunchPlan(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectoryURL: tempDir,
            environment: ["PATH": "/usr/bin:/bin"],
            gameDataDirectoryURL: tempDir.appendingPathComponent("data", isDirectory: true),
            cacheDirectoryURL: tempDir.appendingPathComponent("cache", isDirectory: true),
            profileID: UUID(),
            runtimeReleaseID: "harbor-test"
        ))
        try await supervisor.requestTermination(sessionID: session.id)

        let deadline = Date().addingTimeInterval(10)
        var record: LaunchTimingRecord?
        while Date() < deadline {
            record = LaunchTimingRecorder.recentRecords(directory: paths.metadataDirectory)
                .last { $0.kind == "launch" && $0.outcome != nil }
            if record != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let timing = try XCTUnwrap(record, "launch timing record must be persisted after the session ends")
        XCTAssertEqual(timing.outcome, "cancelled")
        XCTAssertNotNil(
            timing.stageMarks[LaunchTimingStage.compatibilityPreparation.rawValue],
            "launch record must time compatibility preparation"
        )
        XCTAssertNotNil(
            timing.stageMarks[LaunchTimingStage.launchPlanReady.rawValue],
            "launch record must time plan readiness"
        )
        XCTAssertNotNil(timing.stageMarks[LaunchTimingStage.processLaunched.rawValue])
        XCTAssertNotNil(timing.stageMarks[LaunchTimingStage.sessionEnded.rawValue])
    }

    // MARK: - pre-launch helper readiness

    func testPlanRefusesRuntimeWithMissingMicrosoftHelperResources() async throws {
        try writeInstalledPatch(names: ["1.26.40.0"])
        let root = try makeUsableRuntimeRoot(name: "runtime", executableBytes: Data("exec".utf8))
        // A root usable for the game but without the sign-in helper must fail the
        // launch plan with a named piece and the reinstall remediation — not die
        // later as an in-game Microsoft login error (Llama 0x80070057).
        try FileManager.default.removeItem(at: root.appendingPathComponent("MacOS/mcpelauncher-webview"))
        let game = try makeGameInstallation(name: "1.26.40.0")

        let supervisor = ProcessLaunchSupervisor(paths: makePaths())
        do {
            _ = try await supervisor.prepareLaunchPlan(
                profile: Profile(name: "Test"),
                installation: makeInstallation(gameDir: game, versionName: "1.26.40.0"),
                runtime: makeRuntime(root: root, releaseID: "harbor-test")
            )
            XCTFail("prepareLaunchPlan must refuse a runtime without the Microsoft sign-in helper")
        } catch let error as HarborError {
            guard case .unsupportedRuntime(let reason) = error else {
                return XCTFail("expected unsupportedRuntime, got \(error)")
            }
            XCTAssertTrue(reason.contains("mcpelauncher-webview"), "reason must name the missing piece: \(reason)")
            XCTAssertTrue(
                reason.contains("Settings → Runtime → Reinstall the launcher runtime"),
                "reason must carry the remediation: \(reason)"
            )
        }
    }
}
