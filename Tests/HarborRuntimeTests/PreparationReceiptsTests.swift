import XCTest
import Foundation
@testable import HarborRuntime

final class PreparationReceiptsTests: XCTestCase {
    private var tempDir: URL!
    private var compatRoot: URL!
    private var supportRoot: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparationReceiptsTests-\(UUID().uuidString)", isDirectory: true)
        compatRoot = tempDir.appendingPathComponent("CompatibilityPatches", isDirectory: true)
        supportRoot = tempDir.appendingPathComponent("Support", isDirectory: true)
        HarborCompatibilityPatches.harborRootOverride = compatRoot
        LocalRuntimeDiscovery.harborSupportOverride = supportRoot
        LocalRuntimeDiscovery.resetProcessDiscoveryCachesForTesting()
    }

    override func tearDown() {
        HarborCompatibilityPatches.harborRootOverride = nil
        HarborCompatibilityPatches.catalogLoader = nil
        LocalRuntimeDiscovery.harborSupportOverride = nil
        LocalRuntimeDiscovery.resetProcessDiscoveryCachesForTesting()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - fixtures

    /// Valid installed compat patch (Task 4 seam): metadata.json + executable mod .so,
    /// with a universal replacement and a version-pinned rebuild to swap during preparation.
    @discardableResult
    private func writeInstalledPatch(
        version: String = "1.26.45.1",
        names: [String] = ["1.26.45.1", "1.26.51.1"]
    ) throws -> URL {
        let fm = FileManager.default
        let modDir = compatRoot
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("arm64-v8a", isDirectory: true)
        try fm.createDirectory(at: modDir, withIntermediateDirectories: true)
        let mod = modDir.appendingPathComponent(HarborCompatibilityPatches.modLibraryName)
        try Data("fake-mod".utf8).write(to: mod)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mod.path)

        let patchRoot = modDir.appendingPathComponent("patches", isDirectory: true)
        try fm.createDirectory(at: patchRoot, withIntermediateDirectories: true)
        try Data("playfab-rebuild".utf8).write(to: patchRoot.appendingPathComponent("libPlayFabMultiplayer.so"))
        let pinnedDir = patchRoot.appendingPathComponent("v1.26.0.2/arm64-v8a", isDirectory: true)
        try fm.createDirectory(at: pinnedDir, withIntermediateDirectories: true)
        try Data("maesdk-rebuild".utf8).write(to: pinnedDir.appendingPathComponent("libmaesdk.so"))

        let meta = HarborCompatibilityPatches.Metadata(
            version: version,
            assetURL: "https://example.com/asset.zip",
            installPath: modDir.path,
            supportedVersionCodes: [],
            supportedVersionNames: names,
            catalogCheckedAt: Date()
        )
        try JSONEncoder().encode(meta).write(to: compatRoot.appendingPathComponent("metadata.json"))
        return modDir
    }

    /// Fake game package with lib/arm64-v8a libraries.
    private func makeGameDir(name: String = "game") throws -> URL {
        let fm = FileManager.default
        let game = tempDir.appendingPathComponent(name, isDirectory: true)
        let libDir = game.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        try Data("fake-libminecraftpe".utf8).write(to: libDir.appendingPathComponent("libminecraftpe.so"))
        try Data("bundled-playfab".utf8).write(to: libDir.appendingPathComponent("libPlayFabMultiplayer.so"))
        try Data("original-maesdk".utf8).write(to: libDir.appendingPathComponent("libmaesdk.so"))
        return game
    }

    private func mtime(_ url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.modificationDate] as? Date)
    }

    // MARK: - receipt store

    func testReceiptStoreSaveKeepsNewestTwenty() throws {
        var receipts: [PreparationReceipt] = []
        for i in 0..<25 {
            receipts.append(
                PreparationReceipt(
                    gameVersionName: "1.26.\(i).0",
                    gameDirectoryPath: "/tmp/game-\(i)",
                    runtimeRootPath: "/tmp/runtime",
                    patchVersion: "none",
                    bypassedOfficialMod: false,
                    gameLibFingerprints: [:],
                    storagePatchApplied: false,
                    createdAt: Date(timeIntervalSinceNow: Double(i))
                )
            )
        }
        PreparationReceiptStore.save(receipts, root: supportRoot)
        let loaded = PreparationReceiptStore.load(root: supportRoot)
        XCTAssertEqual(loaded.count, 20)
        let names = Set(loaded.map(\.gameVersionName))
        XCTAssertFalse(names.contains("1.26.0.0"), "oldest receipt must be dropped")
        XCTAssertFalse(names.contains("1.26.4.0"))
        XCTAssertTrue(names.contains("1.26.5.0"))
        XCTAssertTrue(names.contains("1.26.24.0"), "newest receipt must be kept")
    }

    func testFingerprintsCoverEveryLibFile() throws {
        let game = try makeGameDir()
        let prints = PreparationReceiptStore.fingerprints(gameDirectory: game)
        XCTAssertEqual(
            Set(prints.keys),
            ["libminecraftpe.so", "libPlayFabMultiplayer.so", "libmaesdk.so"],
            "every file in lib/arm64-v8a must be fingerprinted"
        )
        for (name, value) in prints {
            XCTAssertTrue(value.contains(":"), "\(name) fingerprint must be size:mtime, got \(value)")
        }
        // A game directory without libs fingerprints as empty (nothing to protect).
        let empty = PreparationReceiptStore.fingerprints(
            gameDirectory: tempDir.appendingPathComponent("no-such-game", isDirectory: true)
        )
        XCTAssertEqual(empty, [:])
    }

    // MARK: - receipt fast path (normal launch, official mod used)

    /// Adds a stale in-place patch state: a `.so.bck` pristine backup next to a
    /// modified library, so the normal-path slow pass has restore work to do.
    private func seedStalePatch(game: URL) throws {
        let libDir = game.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        try Data("bundled-playfab".utf8).write(to: libDir.appendingPathComponent("libPlayFabMultiplayer.so.bck"))
        try Data("patched-playfab".utf8).write(to: libDir.appendingPathComponent("libPlayFabMultiplayer.so"))
    }

    func testFirstPreparationAppliesChangesAndWritesReceipt() async throws {
        let modDir = try writeInstalledPatch()
        let game = try makeGameDir()
        try seedStalePatch(game: game)
        let libDir = game.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        let playFab = libDir.appendingPathComponent("libPlayFabMultiplayer.so")
        let before = try mtime(playFab)

        let outcome = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game,
            versionName: "1.26.45.1",
            versionCode: nil,
            runtimeRoot: nil
        )

        XCTAssertFalse(outcome.reusedReceipt)
        XCTAssertEqual(outcome.modDirectory, modDir)
        XCTAssertFalse(outcome.appliedChanges.isEmpty, "first preparation must report applied changes")

        // The restore pass brought the pristine library back from its .bck backup.
        XCTAssertEqual(try Data(contentsOf: playFab), Data("bundled-playfab".utf8))
        XCTAssertNotEqual(try mtime(playFab), before, "restored lib mtime must change on the slow path")

        // Receipt persisted with POST-preparation fingerprints.
        let receipts = PreparationReceiptStore.load(root: supportRoot)
        XCTAssertEqual(receipts.count, 1)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.gameVersionName, "1.26.45.1")
        XCTAssertEqual(receipt.gameDirectoryPath, game.path)
        XCTAssertEqual(receipt.runtimeRootPath, "")
        XCTAssertEqual(receipt.patchVersion, "1.26.45.1")
        XCTAssertFalse(receipt.bypassedOfficialMod)
        XCTAssertEqual(receipt.gameLibFingerprints, PreparationReceiptStore.fingerprints(gameDirectory: game))
    }

    func testSecondIdenticalPreparationReusesReceiptWithoutTouchingLibs() async throws {
        try writeInstalledPatch()
        let game = try makeGameDir()
        try seedStalePatch(game: game)
        let libDir = game.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        let playFab = libDir.appendingPathComponent("libPlayFabMultiplayer.so")
        let minecraftpe = libDir.appendingPathComponent("libminecraftpe.so")

        _ = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.45.1", versionCode: nil, runtimeRoot: nil
        )
        let playFabStamp = try mtime(playFab)
        let minecraftpeStamp = try mtime(minecraftpe)

        let second = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.45.1", versionCode: nil, runtimeRoot: nil
        )

        XCTAssertTrue(second.reusedReceipt, "identical launch inputs must reuse the receipt")
        XCTAssertFalse(second.modDirectory == nil, "receipt reuse must return the mod directory decision")
        XCTAssertTrue(second.appliedChanges.isEmpty, "fast path must not report applied changes")
        // Restore + storage patch were skipped: no file in the game lib dir was touched.
        XCTAssertEqual(try mtime(playFab), playFabStamp)
        XCTAssertEqual(try mtime(minecraftpe), minecraftpeStamp)
        XCTAssertEqual(PreparationReceiptStore.load(root: supportRoot).count, 1, "reuse must not duplicate receipts")
    }

    func testCorruptedLibInvalidatesReceiptAndRerunsSlowPath() async throws {
        try writeInstalledPatch()
        let game = try makeGameDir()
        try seedStalePatch(game: game)
        let libDir = game.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        let playFab = libDir.appendingPathComponent("libPlayFabMultiplayer.so")

        _ = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.45.1", versionCode: nil, runtimeRoot: nil
        )
        let reused = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.45.1", versionCode: nil, runtimeRoot: nil
        )
        XCTAssertTrue(reused.reusedReceipt)

        // Corrupt one library (fingerprint drift): the receipt must fall through to the slow path.
        try Data("corrupted-playfab-bytes".utf8).write(to: playFab)

        let third = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.45.1", versionCode: nil, runtimeRoot: nil
        )
        XCTAssertFalse(third.reusedReceipt)
        XCTAssertFalse(third.appliedChanges.isEmpty, "slow path must re-run the restore pass")
        XCTAssertEqual(try Data(contentsOf: playFab), Data("bundled-playfab".utf8), "slow path must repair the corruption")

        // Receipt rewritten (superseded in place, not duplicated) with the new post-state.
        let receipts = PreparationReceiptStore.load(root: supportRoot)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.gameLibFingerprints, PreparationReceiptStore.fingerprints(gameDirectory: game))

        // And the rewritten receipt is reusable again.
        let fourth = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.45.1", versionCode: nil, runtimeRoot: nil
        )
        XCTAssertTrue(fourth.reusedReceipt)
    }

    func testReceiptInvalidatedByVersionNameDifference() async throws {
        try writeInstalledPatch()
        let game = try makeGameDir()

        _ = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.45.1", versionCode: nil, runtimeRoot: nil
        )
        let other = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.51.1", versionCode: nil, runtimeRoot: nil
        )
        // Different game version is a different receipt identity (here: the bypass path).
        XCTAssertFalse(other.reusedReceipt)
        XCTAssertNil(other.modDirectory, "1.26.51.1 with mod 1.26.45.1 is the known-broken bypass case")
        XCTAssertEqual(PreparationReceiptStore.load(root: supportRoot).count, 2)
    }

    // MARK: - receipt fast path (bypass: official mod known-broken)

    func testBypassPathRecordsBypassedReceiptAndReusesIt() async throws {
        // Stale mod release ("1.26.45.1") for a game in the verified-broken range (1.26.51.1).
        try writeInstalledPatch()
        let game = try makeGameDir()
        let libDir = game.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        let maesdk = libDir.appendingPathComponent("libmaesdk.so")
        let playFab = libDir.appendingPathComponent("libPlayFabMultiplayer.so")

        let first = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.51.1", versionCode: nil, runtimeRoot: nil
        )

        XCTAssertNil(first.modDirectory, "known-incompatibility range must bypass the official mod")
        XCTAssertFalse(first.reusedReceipt)
        XCTAssertFalse(first.appliedChanges.isEmpty)
        // Harbor's own stack ran: universal + version-pinned rebuilds with .bck backups.
        XCTAssertEqual(try Data(contentsOf: playFab), Data("playfab-rebuild".utf8))
        XCTAssertEqual(try Data(contentsOf: maesdk), Data("maesdk-rebuild".utf8))
        XCTAssertEqual(
            try Data(contentsOf: libDir.appendingPathComponent("libmaesdk.so.bck")),
            Data("original-maesdk".utf8)
        )

        let receipts = PreparationReceiptStore.load(root: supportRoot)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertTrue(receipt.bypassedOfficialMod, "receipt must record the bypass decision")
        XCTAssertEqual(receipt.gameVersionName, "1.26.51.1")

        let maesdkStamp = try mtime(maesdk)
        let playFabStamp = try mtime(playFab)

        let second = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.51.1", versionCode: nil, runtimeRoot: nil
        )
        XCTAssertTrue(second.reusedReceipt)
        XCTAssertNil(second.modDirectory, "reused bypass receipt must keep returning nil (no official mod)")
        XCTAssertTrue(second.appliedChanges.isEmpty)
        // Restore + pinned rebuilds were skipped: no lib touched.
        XCTAssertEqual(try mtime(maesdk), maesdkStamp)
        XCTAssertEqual(try mtime(playFab), playFabStamp)
    }

    func testBypassReceiptReinstallsMissingSymbolShim() async throws {
        try writeInstalledPatch()
        let game = try makeGameDir()
        let maesdk = game.appendingPathComponent("lib/arm64-v8a/libmaesdk.so", isDirectory: false)
        let shim = LocalRuntimeDiscovery.harborSupport
            .appendingPathComponent("Patches/1.26.51.1/arm64-v8a/libharbor_symbol_shim.so", isDirectory: false)

        // Slow path installs the symbol shim under Patches/<gameVersion>/arm64-v8a.
        _ = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.51.1", versionCode: nil, runtimeRoot: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: shim.path), "slow path must install the symbol shim")

        // Receipt reuse with the shim still present.
        let reused = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.51.1", versionCode: nil, runtimeRoot: nil
        )
        XCTAssertTrue(reused.reusedReceipt)

        // The Patches/ wipe the layout code anticipates: the shim disappears while the
        // game dir, metadata, and receipt stay valid. The fast path must still reinstall
        // the shim — otherwise the bypassed game launches with no -m mod at all, the
        // exact startup crash the shim prevents.
        try FileManager.default.removeItem(at: shim)
        let maesdkStamp = try mtime(maesdk)

        let afterWipe = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
            gameDirectory: game, versionName: "1.26.51.1", versionCode: nil, runtimeRoot: nil
        )
        XCTAssertTrue(afterWipe.reusedReceipt, "game-dir state is unchanged; the receipt still applies")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: shim.path),
            "a bypass receipt hit must reinstall a missing symbol shim before returning"
        )
        XCTAssertFalse(
            LocalRuntimeDiscovery.harborModsPaths(gameVersionName: "1.26.51.1").isEmpty,
            "the reinstalled shim must be visible to the -m mod paths again"
        )
        XCTAssertEqual(try mtime(maesdk), maesdkStamp, "game libs stay untouched (no slow-path re-run)")
    }
}
