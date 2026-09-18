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

    // MARK: - universal game libraries

    func testApplyUniversalGameLibrariesSwapsOnlyRootLevelLibs() throws {
        let fm = FileManager.default
        let patchRoot = tempDir.appendingPathComponent("moddir/patches", isDirectory: true)
        let versioned = patchRoot.appendingPathComponent("v1.26.0.2/arm64-v8a", isDirectory: true)
        try fm.createDirectory(at: versioned, withIntermediateDirectories: true)
        let gameLib = tempDir.appendingPathComponent("game/lib/arm64-v8a", isDirectory: true)
        try fm.createDirectory(at: gameLib, withIntermediateDirectories: true)

        let universal = Data("playfab-rebuild".utf8)
        try universal.write(to: patchRoot.appendingPathComponent("libPlayFabMultiplayer.so"))
        try Data("old-maesdk-patch".utf8).write(to: versioned.appendingPathComponent("libmaesdk.so"))
        try Data("bundled-playfab".utf8).write(to: gameLib.appendingPathComponent("libPlayFabMultiplayer.so"))
        try Data("original-maesdk".utf8).write(to: gameLib.appendingPathComponent("libmaesdk.so"))

        let applied = HarborCompatibilityPatches.applyUniversalGameLibraries(
            modDirectory: tempDir.appendingPathComponent("moddir", isDirectory: true),
            gameDirectory: tempDir.appendingPathComponent("game", isDirectory: true)
        )

        XCTAssertEqual(applied, ["libPlayFabMultiplayer.so"])
        XCTAssertEqual(try Data(contentsOf: gameLib.appendingPathComponent("libPlayFabMultiplayer.so")), universal)
        XCTAssertEqual(
            try Data(contentsOf: gameLib.appendingPathComponent("libPlayFabMultiplayer.so.bck")),
            Data("bundled-playfab".utf8)
        )
        // Version-pinned patch libs are never applied by the universal pass.
        XCTAssertEqual(
            try Data(contentsOf: gameLib.appendingPathComponent("libmaesdk.so")),
            Data("original-maesdk".utf8)
        )

        // Idempotent: second run is a no-op (contents already match).
        let second = HarborCompatibilityPatches.applyUniversalGameLibraries(
            modDirectory: tempDir.appendingPathComponent("moddir", isDirectory: true),
            gameDirectory: tempDir.appendingPathComponent("game", isDirectory: true)
        )
        XCTAssertEqual(second, [])
    }

    // MARK: - guest libc hash repair

    /// Minimal synthetic ELF64 with a hash-broken `pthread_sigmask` and a safe victim in the
    /// same GNU-hash bucket run, shaped like the real macos-builder v1.8.4-573 build bug.
    private func makeSyntheticLibc() -> Data? {
        let victimName = "_ZZN11__llvm_libc8internal18strtofloatingpointIfEENS_14StrToNumResultIT_EEPKcE10inf_string"
        let targetName = "pthread_sigmask"
        let strtab = ["", victimName, targetName]
        var dynstr = Data()
        var nameOffsets: [Int] = []
        for s in strtab {
            nameOffsets.append(dynstr.count)
            dynstr.append(Data(s.utf8))
            dynstr.append(0)
        }

        func symEntry(nameOff: Int, info: UInt8, shndx: UInt16, value: UInt64, size: UInt64) -> Data {
            var e = Data()
            e.appendLE(UInt32(nameOff))
            e.append(info)
            e.append(0)
            e.appendLE(shndx)
            e.appendLE(value)
            e.appendLE(size)
            XCTAssertEqual(e.count, 24)
            return e
        }
        // dynsym: null, victim (hashed, defined), target (appended, defined, NOT hashed)
        var dynsym = symEntry(nameOff: 0, info: 0, shndx: 0, value: 0, size: 0)
        dynsym.append(symEntry(nameOff: nameOffsets[1], info: 0x11, shndx: 1, value: 0x1000, size: 16))
        dynsym.append(symEntry(nameOff: nameOffsets[2], info: 0x12, shndx: 1, value: 0x516d4, size: 0x918))

        let symbolOffset = 1
        let nbuckets = 1
        let bloomSize = 1
        let bloomShift = 6
        var gnuHash = Data()
        gnuHash.appendLE(UInt32(nbuckets))
        gnuHash.appendLE(UInt32(symbolOffset))
        gnuHash.appendLE(UInt32(bloomSize))
        gnuHash.appendLE(UInt32(bloomShift))
        gnuHash.appendLE(UInt64(0)) // bloom word (patcher sets bits)
        gnuHash.appendLE(UInt32(1)) // bucket[0] -> run starts at victim index 1
        gnuHash.appendLE(UInt32(0x1234)) // chain[1] = victim hash (no lsb) — run continues
        gnuHash.appendLE(UInt32(0x5678 | 1)) // chain[2] terminator (target never in chain)

        var shstr = Data()
        func shstrOffset(_ s: String) -> Int {
            let off = shstr.count
            shstr.append(Data(s.utf8)); shstr.append(0)
            return off
        }
        // Section layout: 0 null, 1 .text, 2 .dynsym, 3 .dynstr, 4 .gnu.hash, 5 .shstrtab
        let names = ["", ".text", ".dynsym", ".dynstr", ".gnu.hash", ".shstrtab"]
        var nameOffs: [Int] = []
        _ = shstrOffset("") // keep first byte null
        for n in names[1...] { nameOffs.append(shstrOffset(n)) }

        let ehsize = 64
        var offsets: [Int] = []
        var cursor = ehsize
        for blob in [Data(repeating: 0x90, count: 64), dynsym, dynstr, gnuHash, shstr] {
            offsets.append(cursor)
            cursor += blob.count
        }
        let shoff = cursor

        func shdr(nameOff: Int, type: Int, offset: Int, size: Int) -> Data {
            var d = Data()
            d.appendLE(UInt32(nameOff))
            d.appendLE(UInt32(type))
            d.appendLE(UInt64(0)) // flags
            d.appendLE(UInt64(0)) // addr
            d.appendLE(UInt64(offset))
            d.appendLE(UInt64(size))
            d.appendLE(UInt32(0)) // link
            d.appendLE(UInt32(0)) // info
            d.appendLE(UInt64(1)) // addralign
            d.appendLE(UInt64(0)) // entsize
            XCTAssertEqual(d.count, 64)
            return d
        }

        var out = Data()
        out.append(Data([0x7f, UInt8(ascii: "E"), UInt8(ascii: "L"), UInt8(ascii: "F"), 2, 1, 0]))
        out.append(Data(repeating: 0, count: 64 - out.count - 0))
        out.replaceSubrange(0x28..<0x30, with: withUnsafeLE(UInt64(shoff)))
        out.replaceSubrange(0x3a..<0x3c, with: withUnsafeLE(UInt16(64)))
        out.replaceSubrange(0x3c..<0x3e, with: withUnsafeLE(UInt16(6)))
        out.replaceSubrange(0x3e..<0x40, with: withUnsafeLE(UInt16(5)))
        // section data blobs
        var blobs: [Int: Data] = [:]
        blobs[1] = Data(repeating: 0x90, count: 64)
        blobs[2] = dynsym
        blobs[3] = dynstr
        blobs[4] = gnuHash
        blobs[5] = shstr
        out.removeSubrange(ehsize..<out.count)
        for i in 1...5 { out.append(blobs[i]!) }
        // section headers
        out.append(shdr(nameOff: 0, type: 0, offset: 0, size: 0))
        out.append(shdr(nameOff: nameOffs[0], type: 1, offset: offsets[0], size: blobs[1]!.count))
        out.append(shdr(nameOff: nameOffs[1], type: 11, offset: offsets[1], size: blobs[2]!.count))
        out.append(shdr(nameOff: nameOffs[2], type: 3, offset: offsets[2], size: blobs[3]!.count))
        out.append(shdr(nameOff: nameOffs[3], type: 0x6ffffff6, offset: offsets[3], size: blobs[4]!.count))
        out.append(shdr(nameOff: nameOffs[4], type: 3, offset: offsets[4], size: blobs[5]!.count))
        return out
    }

    func testGuestLibcRepairFixesHashReachability() throws {
        guard var data = makeSyntheticLibc() else {
            return XCTFail("synthetic libc construction failed")
        }
        guard let elf = Elf64.parse(data: data) else {
            return XCTFail("synthetic libc does not parse")
        }
        let dynsym = try XCTUnwrap(elf.section(".dynsym"))
        let dynstr = try XCTUnwrap(elf.section(".dynstr"))
        let gnuHashSection = try XCTUnwrap(elf.section(".gnu.hash"))
        let gnu = try XCTUnwrap(GnuHash.parse(data: data, section: gnuHashSection, dynsymCount: dynsym.size / 24))

        XCTAssertNil(gnu.lookup(data: data, elf: elf, dynsym: dynsym, dynstr: dynstr, name: "pthread_sigmask"))

        let result = GuestLibcCompatibilityPatch.repair(elf: elf, data: &data)
        guard case .success = result else {
            return XCTFail("repair refused: \(result)")
        }

        let patchedElf = try XCTUnwrap(Elf64.parse(data: data))
        let patchedSym = try XCTUnwrap(patchedElf.section(".dynsym"))
        let patchedStr = try XCTUnwrap(patchedElf.section(".dynstr"))
        let patchedGnuSection = try XCTUnwrap(patchedElf.section(".gnu.hash"))
        let patchedGnu = try XCTUnwrap(GnuHash.parse(data: data, section: patchedGnuSection, dynsymCount: patchedSym.size / 24))
        let found = try XCTUnwrap(
            patchedGnu.lookup(data: data, elf: patchedElf, dynsym: patchedSym, dynstr: patchedStr, name: "pthread_sigmask")
        )
        XCTAssertEqual(found, 1) // repurposed victim entry
        let entry = try XCTUnwrap(patchedElf.symbol(data: data, index: 1))
        XCTAssertEqual(entry.value, 0x516d4)
        XCTAssertEqual(entry.size, 0x918)

        // Idempotent: second repair reports already patched.
        var again = data
        let second = GuestLibcCompatibilityPatch.repair(elf: patchedElf, data: &again)
        guard case .failure(let report) = second, report.state == .alreadyPatched else {
            return XCTFail("expected alreadyPatched, got \(second)")
        }
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: UInt64) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

private func withUnsafeLE(_ v: UInt64) -> Data {
    var le = v.littleEndian
    return Swift.withUnsafeBytes(of: &le) { Data($0) }
}

private func withUnsafeLE(_ v: UInt16) -> Data {
    var le = v.littleEndian
    return Swift.withUnsafeBytes(of: &le) { Data($0) }
}
