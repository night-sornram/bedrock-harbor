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
        // The Microsoft sign-in helper — deploy validates it after copying
        // (validateHelperResources), so the fixture must carry the full layout.
        let webview = contents.appendingPathComponent("MacOS/mcpelauncher-webview")
        try "#!/bin/sh\nexit 0\n".write(to: webview, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: webview.path)
        // The bundle's Qt plugins — mcpelauncher-webview (Microsoft sign-in) aborts
        // without the cocoa platform plugin.
        try fm.createDirectory(at: contents.appendingPathComponent("PlugIns/platforms"), withIntermediateDirectories: true)
        try "fake cocoa plugin".write(
            to: contents.appendingPathComponent("PlugIns/platforms/libqcocoa.dylib"),
            atomically: true,
            encoding: .utf8
        )
        // QML modules the helper resolves through its executable-side qt.conf.
        try fm.createDirectory(at: contents.appendingPathComponent("Resources/qml/QtQuick"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources/qml/QtWebEngine"), withIntermediateDirectories: true)
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

    func testDeployWritesExecutableSideQtConfSoWebviewFindsQmlModules() throws {
        let contents = try makeFakeAppContents()
        let dest = tempDir.appendingPathComponent("harbor-mcpelauncher-test", isDirectory: true)

        try HarborRuntimeInstaller.deploy(appContents: contents, destination: dest)

        // mcpelauncher-webview (Xbox sign-in) aborts with "module QtQuick.Controls
        // is not installed" unless a qt.conf next to the executable anchors the
        // prefix at the runtime root — the bundle's Resources/qt.conf alone is not
        // consulted for QML imports when the binary runs outside a real app bundle.
        let expected = "[Paths]\nPrefix = ..\nPlugins = PlugIns\nImports = Resources/qml\nQmlImports = Resources/qml\n"
        let actual = try String(
            contentsOf: dest.appendingPathComponent("MacOS/qt.conf"),
            encoding: .utf8
        )
        XCTAssertEqual(actual, expected)
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
        // PlugIns without the executable-side qt.conf still yield a sign-in webview
        // that cannot resolve its QML modules — require the fix so pre-fix runtimes
        // self-heal instead of failing Xbox login with Llama 0x80070057.
        XCTAssertFalse(LocalRuntimeDiscovery.isRuntimeRootUsable(root))

        try "[Paths]\nPrefix = ..\n".write(
            to: root.appendingPathComponent("MacOS/qt.conf"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(LocalRuntimeDiscovery.isRuntimeRootUsable(root))
    }

    func testDeployStripsQuarantineFromDeployedRuntime() throws {
        let contents = try makeFakeAppContents()
        // A browser-downloaded engine DMG carries com.apple.quarantine on its files.
        // Gatekeeper then blocks the sign-in webview's plugins ("Apple could not
        // verify…") when the game spawns mcpelauncher-webview — deploy must strip it.
        let sourcePaths = [
            contents.appendingPathComponent("PlugIns/platforms/libqcocoa.dylib").path,
            contents.appendingPathComponent("MacOS/mcpelauncher-client").path,
        ]
        for path in sourcePaths {
            XCTAssertTrue(try runXAttr(["-w", "com.apple.quarantine", "0081;00000000;Safari;test", path]))
        }
        let dest = tempDir.appendingPathComponent("harbor-mcpelauncher-test", isDirectory: true)

        try HarborRuntimeInstaller.deploy(appContents: contents, destination: dest)

        for source in sourcePaths {
            let deployed = source.replacingOccurrences(of: contents.path, with: dest.path)
            XCTAssertFalse(
                try runXAttr(["-p", "com.apple.quarantine", deployed]),
                "quarantine survived deploy: \(deployed)"
            )
        }
    }

    private func runXAttr(_ arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
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

    // MARK: - Microsoft helper-resource validation

    /// Runtime root carrying every helper resource `validateHelperResources`
    /// checks (the pinned DMG layout, with qt.conf as deploy writes it).
    private func makeFullHelperRuntimeRoot() throws -> URL {
        let fm = FileManager.default
        let root = tempDir.appendingPathComponent("helper-root-\(UUID().uuidString)", isDirectory: true)
        for rel in ["MacOS", "PlugIns/platforms", "Resources/qml/QtQuick", "Resources/qml/QtWebEngine"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(rel, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let webview = root.appendingPathComponent("MacOS/mcpelauncher-webview")
        try "#!/bin/sh\nexit 0\n".write(to: webview, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: webview.path)
        try "fake cocoa plugin".write(
            to: root.appendingPathComponent("PlugIns/platforms/libqcocoa.dylib"),
            atomically: true,
            encoding: .utf8
        )
        try "[Paths]\nPrefix = ..\n".write(
            to: root.appendingPathComponent("MacOS/qt.conf"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    func testValidateHelperResourcesAcceptsFullRuntimeRoot() throws {
        let root = try makeFullHelperRuntimeRoot()
        XCTAssertEqual(HarborRuntimeInstaller.validateHelperResources(root: root), [])
    }

    func testValidateHelperResourcesNamesEachMissingPiece() throws {
        let pieces: [(name: String, path: String)] = [
            ("Microsoft sign-in helper (MacOS/mcpelauncher-webview)", "MacOS/mcpelauncher-webview"),
            ("Qt platform plugin (PlugIns/platforms/libqcocoa.dylib)", "PlugIns/platforms/libqcocoa.dylib"),
            ("Qt configuration (MacOS/qt.conf)", "MacOS/qt.conf"),
            ("QtQuick modules (Resources/qml/QtQuick)", "Resources/qml/QtQuick"),
            ("QtWebEngine modules (Resources/qml/QtWebEngine)", "Resources/qml/QtWebEngine"),
        ]
        for piece in pieces {
            let root = try makeFullHelperRuntimeRoot()
            try FileManager.default.removeItem(at: root.appendingPathComponent(piece.path))
            XCTAssertEqual(
                HarborRuntimeInstaller.validateHelperResources(root: root),
                [piece.name],
                "removing \(piece.path) must name exactly that piece"
            )
        }
    }

    func testValidateHelperResourcesRequiresExecutableWebview() throws {
        let root = try makeFullHelperRuntimeRoot()
        // A webview present but not executable cannot be spawned by the game.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: root.appendingPathComponent("MacOS/mcpelauncher-webview").path
        )
        XCTAssertEqual(
            HarborRuntimeInstaller.validateHelperResources(root: root),
            ["Microsoft sign-in helper (MacOS/mcpelauncher-webview)"]
        )
    }

    func testDeployRejectsBundleMissingMicrosoftSignInHelper() throws {
        let contents = try makeFakeAppContents()
        try FileManager.default.removeItem(at: contents.appendingPathComponent("MacOS/mcpelauncher-webview"))

        XCTAssertThrowsError(
            try HarborRuntimeInstaller.deploy(
                appContents: contents,
                destination: tempDir.appendingPathComponent("dest", isDirectory: true)
            )
        ) { error in
            guard case HarborError.invalidPackage(let reason) = error else {
                return XCTFail("expected invalidPackage, got \(error)")
            }
            XCTAssertTrue(reason.contains("mcpelauncher-webview"), "reason must list the missing piece: \(reason)")
        }
    }

    func testRuntimeReadinessRunsTheSameChecksAsInstallValidation() throws {
        let full = try makeFullHelperRuntimeRoot()
        XCTAssertEqual(RuntimeReadiness.missingPieces(runtimeRoot: full), [])

        try FileManager.default.removeItem(at: full.appendingPathComponent("Resources/qml/QtWebEngine"))
        XCTAssertEqual(
            RuntimeReadiness.missingPieces(runtimeRoot: full),
            ["QtWebEngine modules (Resources/qml/QtWebEngine)"]
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
