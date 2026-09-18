import XCTest
@testable import HarborRuntime
import HarborDomain

final class HarborRuntimeInstallerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborRuntimeInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeFakeAppContents() throws -> URL {
        let fm = FileManager.default
        let contents = tempDir.appendingPathComponent("Minecraft Bedrock Launcher.app/Contents", isDirectory: true)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources/mcpelauncher/lib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let client = contents.appendingPathComponent("MacOS/mcpelauncher-client")
        try "#!/bin/sh\nexit 0\n".write(to: client, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        // The bundle's Qt plugins — mcpelauncher-webview (Microsoft sign-in) aborts
        // without the cocoa platform plugin.
        try fm.createDirectory(at: contents.appendingPathComponent("PlugIns/platforms"), withIntermediateDirectories: true)
        try "fake cocoa plugin".write(
            to: contents.appendingPathComponent("PlugIns/platforms/libqcocoa.dylib"),
            atomically: true,
            encoding: .utf8
        )
        try "controller db".write(
            to: contents.appendingPathComponent("Resources/mcpelauncher/gamecontrollerdb.txt"),
            atomically: true,
            encoding: .utf8
        )
        return contents
    }

    // MARK: - deploy layout

    func testDeployCreatesRunnableRuntimeLayout() throws {
        let contents = try makeFakeAppContents()
        let dest = tempDir.appendingPathComponent("harbor-mcpelauncher-test", isDirectory: true)

        try HarborRuntimeInstaller.deploy(appContents: contents, destination: dest)

        let fm = FileManager.default
        XCTAssertTrue(fm.isExecutableFile(atPath: dest.appendingPathComponent("MacOS/mcpelauncher-client").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("Frameworks").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("share/mcpelauncher/gamecontrollerdb.txt").path))

        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dest.appendingPathComponent("runtime.json"))
        ) as? [String: String]
        XCTAssertEqual(json?["version"], HarborRuntimeInstaller.versionLabel)
        XCTAssertEqual(json?["sourceURL"], HarborRuntimeInstaller.sourceURL.absoluteString)
        // LocalRuntimeDiscovery reads runtime.json "version" — install directory must match.
        XCTAssertEqual(HarborRuntimeInstaller.installDirectoryName, "harbor-mcpelauncher-\(HarborRuntimeInstaller.versionLabel)")
    }

    func testDeployReplacesExistingDestinationCleanly() throws {
        let contents = try makeFakeAppContents()
        let dest = tempDir.appendingPathComponent("harbor-mcpelauncher-test", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dest.appendingPathComponent("MacOS/stale-dir"),
            withIntermediateDirectories: true
        )

        try HarborRuntimeInstaller.deploy(appContents: contents, destination: dest)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("MacOS/stale-dir").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.appendingPathComponent("MacOS/mcpelauncher-client").path))
    }

    func testDeployCopiesQtPlugInsSoSignInWebviewCanStart() throws {
        let contents = try makeFakeAppContents()
        let dest = tempDir.appendingPathComponent("harbor-mcpelauncher-test", isDirectory: true)

        try HarborRuntimeInstaller.deploy(appContents: contents, destination: dest)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("PlugIns/platforms/libqcocoa.dylib").path
            ),
            "deploy must copy the app bundle's PlugIns — without libqcocoa.dylib the Xbox sign-in webview crashes"
        )
    }

    func testDeployRejectsBundleWithoutPlugIns() throws {
        let contents = try makeFakeAppContents()
        try FileManager.default.removeItem(at: contents.appendingPathComponent("PlugIns"))

        XCTAssertThrowsError(
            try HarborRuntimeInstaller.deploy(
                appContents: contents,
                destination: tempDir.appendingPathComponent("dest", isDirectory: true)
            )
        )
    }

    func testRuntimeRootUsableRequiresLoginWebviewPlugin() throws {
        let fm = FileManager.default
        let root = tempDir.appendingPathComponent("runtime-root", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let client = root.appendingPathComponent("MacOS/mcpelauncher-client")
        try "#!/bin/sh\nexit 0\n".write(to: client, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)

        // Client alone is not enough — the sign-in webview needs its platform plugin.
        XCTAssertFalse(LocalRuntimeDiscovery.isRuntimeRootUsable(root))

        try fm.createDirectory(at: root.appendingPathComponent("PlugIns/platforms"), withIntermediateDirectories: true)
        try "plugin".write(
            to: root.appendingPathComponent("PlugIns/platforms/libqcocoa.dylib"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(LocalRuntimeDiscovery.isRuntimeRootUsable(root))
    }

    func testDeployRejectsNonAppBundle() throws {
        let notAnApp = tempDir.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: notAnApp, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try HarborRuntimeInstaller.deploy(
                appContents: notAnApp,
                destination: tempDir.appendingPathComponent("dest", isDirectory: true)
            )
        )
    }

    // MARK: - live self-heal (opt-in via env: HARBOR_LIVE_INSTALL_TEST=1 with isolated HOME)

    /// Full install path against an isolated HOME ($HOME/<…>/BedrockHarbor/Runtimes).
    /// Requires the launcher DMG to be pre-cached in that HOME's _downloads
    /// (no network) so CI/regular runs stay offline — otherwise skipped.
    func testLiveSelfHealInstallFromCachedDMG() async throws {
        guard ProcessInfo.processInfo.environment["HARBOR_LIVE_INSTALL_TEST"] == "1" else {
            throw XCTSkip("Set HARBOR_LIVE_INSTALL_TEST=1 and an isolated HOME with a cached DMG to run this")
        }
        let installed = try await HarborRuntimeInstaller.ensureInstalled(status: { _ in })
        XCTAssertTrue(installed, "clean Runtimes/ dir must result in a fresh install")
        XCTAssertTrue(HarborRuntimeInstaller.runtimePresent())
        // Second call is a no-op returning false — nothing to reinstall.
        let again = try await HarborRuntimeInstaller.ensureInstalled(status: { _ in })
        XCTAssertFalse(again)
    }
}
