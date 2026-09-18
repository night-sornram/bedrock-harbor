import XCTest
@testable import HarborRuntime
import HarborDomain

final class CompatibilityPatchesTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborCompatTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - version name matching

    func testVersionComponentsNormalizes() {
        XCTAssertEqual(HarborCompatibilityPatches.versionComponents("1.26.51.1"), [1, 26, 51, 1])
        XCTAssertEqual(HarborCompatibilityPatches.versionComponents("v26.40.1"), [26, 40, 1])
        XCTAssertEqual(HarborCompatibilityPatches.versionComponents("1.26.51"), [1, 26, 51])
        XCTAssertEqual(HarborCompatibilityPatches.versionComponents("not-a-version"), [])
    }

    func testVersionNameMatchesExactAndThreeComponentPrefix() {
        XCTAssertTrue(HarborCompatibilityPatches.versionNameMatches("1.26.51.1", supported: "1.26.51.1"))
        XCTAssertTrue(HarborCompatibilityPatches.versionNameMatches("1.26.51.1", supported: "1.26.51"))
        XCTAssertTrue(HarborCompatibilityPatches.versionNameMatches("1.26.51", supported: "1.26.51.1"))
    }

    func testVersionNameMatchesRejectsDifferentPatchVersion() {
        XCTAssertFalse(HarborCompatibilityPatches.versionNameMatches("1.26.51.1", supported: "1.26.50.4"))
        XCTAssertFalse(HarborCompatibilityPatches.versionNameMatches("1.26.51.1", supported: "1.26.45.1"))
        // Short names must not over-match.
        XCTAssertFalse(HarborCompatibilityPatches.versionNameMatches("1.26", supported: "1.26.51.1"))
        XCTAssertFalse(HarborCompatibilityPatches.versionNameMatches("garbage", supported: "1.26.51.1"))
    }

    // MARK: - metadata support

    private func makeMetadata(
        codes: [Int] = [],
        names: [String] = []
    ) -> HarborCompatibilityPatches.Metadata {
        HarborCompatibilityPatches.Metadata(
            version: "1.26.45.1",
            assetURL: "https://example.com/asset.zip",
            installPath: "/tmp/none",
            supportedVersionCodes: codes,
            supportedVersionNames: names
        )
    }

    func testMetadataSupportsByCode() {
        let meta = makeMetadata(codes: [972605101])
        XCTAssertTrue(HarborCompatibilityPatches.metadataSupports(meta, versionCode: 972605101, versionName: nil))
        XCTAssertFalse(HarborCompatibilityPatches.metadataSupports(meta, versionCode: 972605100, versionName: nil))
    }

    func testMetadataSupportsByName() {
        let meta = makeMetadata(names: ["1.26.45.1", "1.26.51.1"])
        XCTAssertTrue(HarborCompatibilityPatches.metadataSupports(meta, versionCode: nil, versionName: "1.26.51.1"))
        XCTAssertFalse(HarborCompatibilityPatches.metadataSupports(meta, versionCode: nil, versionName: "1.26.99.0"))
    }

    func testMaxSupportedVersionName() {
        XCTAssertEqual(
            HarborCompatibilityPatches.maxSupportedVersionName(in: ["1.26.45.1", "1.26.51.1", "1.26.50.4"]),
            "1.26.51.1"
        )
        XCTAssertNil(HarborCompatibilityPatches.maxSupportedVersionName(in: []))
    }

    // MARK: - install reuse decision

    func testShouldReuseInstalledSameVersion() {
        XCTAssertTrue(
            HarborCompatibilityPatches.shouldReuseInstalled(
                installedVersion: "1.26.45.1",
                installedAssetURL: "https://example.com/a.zip",
                coversGame: false,
                latestVersion: "1.26.45.1",
                latestAssetURL: "https://example.com/b.zip"
            )
        )
    }

    func testShouldReuseInstalledSameAssetRequiresGameCoverage() {
        let args: (String?, String, Bool?) = ("26.40.1", "1.26.45.1", nil)
        // Same asset URL, game covered -> reuse (asset bytes already support the game).
        XCTAssertTrue(
            HarborCompatibilityPatches.shouldReuseInstalled(
                installedVersion: args.0,
                installedAssetURL: "https://example.com/a.zip",
                coversGame: true,
                latestVersion: args.1,
                latestAssetURL: "https://example.com/a.zip"
            )
        )
        // Same asset URL, game NOT covered -> refresh (upstream may have rebuilt the asset).
        XCTAssertFalse(
            HarborCompatibilityPatches.shouldReuseInstalled(
                installedVersion: args.0,
                installedAssetURL: "https://example.com/a.zip",
                coversGame: false,
                latestVersion: args.1,
                latestAssetURL: "https://example.com/a.zip"
            )
        )
        // No game version context -> identical bytes are fine.
        XCTAssertTrue(
            HarborCompatibilityPatches.shouldReuseInstalled(
                installedVersion: args.0,
                installedAssetURL: "https://example.com/a.zip",
                coversGame: nil,
                latestVersion: args.1,
                latestAssetURL: "https://example.com/a.zip"
            )
        )
    }

    func testShouldReuseInstalledDifferentAssetNeverReused() {
        XCTAssertFalse(
            HarborCompatibilityPatches.shouldReuseInstalled(
                installedVersion: "26.40.1",
                installedAssetURL: "https://example.com/a.zip",
                coversGame: true,
                latestVersion: "1.26.45.1",
                latestAssetURL: "https://example.com/b.zip"
            )
        )
        XCTAssertFalse(
            HarborCompatibilityPatches.shouldReuseInstalled(
                installedVersion: nil,
                installedAssetURL: "https://example.com/a.zip",
                coversGame: true,
                latestVersion: "1.26.45.1",
                latestAssetURL: "https://example.com/a.zip"
            )
        )
    }

    // MARK: - known incompatibilities

    func testModVersionComponentsNormalizesLegacyScheme() {
        XCTAssertEqual(HarborCompatibilityPatches.modVersionComponents("26.40.1"), [1, 26, 40, 1])
        XCTAssertEqual(HarborCompatibilityPatches.modVersionComponents("1.26.45.1"), [1, 26, 45, 1])
        XCTAssertEqual(HarborCompatibilityPatches.modVersionComponents("1.21.132.1"), [1, 21, 132, 1])
    }

    func testKnownIncompatibilityBlocksVerifiedCrashingGeneration() {
        // Verified: 1.26.51.1 crashes with every published mod release.
        XCTAssertNotNil(HarborCompatibilityPatches.knownIncompatibility(gameVersionName: "1.26.51.1", modVersion: "1.26.45.1"))
        XCTAssertNotNil(HarborCompatibilityPatches.knownIncompatibility(gameVersionName: "1.26.51.1", modVersion: "26.40.1"))
        XCTAssertNotNil(HarborCompatibilityPatches.knownIncompatibility(gameVersionName: "1.26.50.4", modVersion: "26.40.1"))
    }

    func testKnownIncompatibilityAllowsOtherVersions() {
        XCTAssertNil(HarborCompatibilityPatches.knownIncompatibility(gameVersionName: "1.26.45.1", modVersion: "1.26.45.1"))
        XCTAssertNil(HarborCompatibilityPatches.knownIncompatibility(gameVersionName: "1.26.20.4", modVersion: "26.40.1"))
        // Versions beyond the verified range are handled by the moddb coverage gate instead.
        XCTAssertNil(HarborCompatibilityPatches.knownIncompatibility(gameVersionName: "1.26.52.0", modVersion: "1.26.45.1"))
        XCTAssertNil(HarborCompatibilityPatches.knownIncompatibility(gameVersionName: "garbage", modVersion: "1.26.45.1"))
    }

    func testKnownIncompatibilityLiftsWithNewerModRelease() {
        // A future mod release must clear the block so Harbor tries the fix.
        XCTAssertNil(HarborCompatibilityPatches.knownIncompatibility(gameVersionName: "1.26.51.1", modVersion: "1.26.51.1"))
        XCTAssertNil(HarborCompatibilityPatches.knownIncompatibility(gameVersionName: "1.26.51.1", modVersion: "1.26.46.0"))
    }

    // MARK: - game library restore

    func testRestorePatchedGameLibrariesRestoresFromBackups() throws {
        let libDir = tempDir.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        let original = Data("original-maesdk".utf8)
        let patched = Data("patched-maesdk".utf8)
        try original.write(to: libDir.appendingPathComponent("libmaesdk.so.bck"))
        try patched.write(to: libDir.appendingPathComponent("libmaesdk.so"))
        try original.write(to: libDir.appendingPathComponent("libPlayFabMultiplayer.so.bck"))
        try original.write(to: libDir.appendingPathComponent("libPlayFabMultiplayer.so"))
        // Unrelated backups must be ignored.
        try Data("x".utf8).write(to: libDir.appendingPathComponent("libmaesdk.so.bck1"))
        try Data("x".utf8).write(to: libDir.appendingPathComponent("libminecraftpe.so.harborbak"))

        let restored = HarborCompatibilityPatches.restorePatchedGameLibraries(gameDirectory: tempDir)

        XCTAssertEqual(Set(restored), ["libmaesdk.so", "libPlayFabMultiplayer.so"])
        XCTAssertEqual(try Data(contentsOf: libDir.appendingPathComponent("libmaesdk.so")), original)
        XCTAssertEqual(
            try Data(contentsOf: libDir.appendingPathComponent("libPlayFabMultiplayer.so")),
            original
        )
        // Idempotent: a second run restores the same pristine bytes.
        _ = HarborCompatibilityPatches.restorePatchedGameLibraries(gameDirectory: tempDir)
        XCTAssertEqual(try Data(contentsOf: libDir.appendingPathComponent("libmaesdk.so")), original)
    }

    func testRestorePatchedGameLibrariesWithMissingLibDir() {
        let restored = HarborCompatibilityPatches.restorePatchedGameLibraries(
            gameDirectory: tempDir.appendingPathComponent("no-such-game", isDirectory: true)
        )
        XCTAssertEqual(restored, [])
    }
}
