import XCTest
@testable import HarborRuntime

final class StorageQueryCompatibilityPatchTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborStoragePatchTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - aarch64 encoders

    private func adrp(rd: UInt32, targetVaddr: UInt64, pc: UInt64) -> UInt32 {
        let pcPage = Int64(bitPattern: pc & ~0xFFF)
        let targetPage = Int64(bitPattern: targetVaddr & ~0xFFF)
        let imm = (targetPage - pcPage) >> 12
        let immlo = UInt32(truncatingIfNeeded: imm) & 0x3
        let immhi = UInt32(truncatingIfNeeded: (imm >> 2) & 0x7FFFF)
        return 0x9000_0000 | (immlo << 29) | (immhi << 5) | rd
    }

    private func addImm(rd: UInt32, rn: UInt32, imm12: UInt32) -> UInt32 {
        0x9100_0000 | (imm12 << 10) | (rn << 5) | rd
    }

    private func bl(pc: UInt64, target: UInt64) -> UInt32 {
        let off = Int64(target) - Int64(pc)
        precondition(off % 4 == 0)
        return 0x9400_0000 | UInt32(truncatingIfNeeded: (off >> 2) & 0x3FF_FFFF)
    }

    private let ret: UInt32 = 0xd65f_03c0

    // MARK: - synthetic game library

    private struct Fixture {
        var data: Data
        var expectedPatchOffset: Int
    }

    /// Synthetic aarch64 ELF64 shaped like Bedrock 1.26.5x `libminecraftpe.so`: two JNI
    /// storage-query call sites (getTotalSpace, getUsableSpace) that share a string-conversion
    /// helper and a CallStaticLongMethodA helper, with the total-space call as the last shared
    /// `bl` in its window.
    private func makeSyntheticGameLib(
        duplicateTotalString: Bool = false,
        omitTotalString: Bool = false,
        prePatched: Bool = false
    ) -> Fixture? {
        let textVaddr: UInt64 = 0x10000
        let rodataVaddr: UInt64 = 0x20000

        var rodata = Data()
        func rodataString(_ s: String) -> (offset: UInt32, vaddr: UInt64) {
            let off = rodata.count
            rodata.append(Data(s.utf8))
            rodata.append(0)
            return (UInt32(off), rodataVaddr + UInt64(off))
        }

        let sig = rodataString("(Ljava/lang/String;)J")
        let usable = rodataString("getUsableSpace")
        let total = omitTotalString ? nil : rodataString("getTotalSpace")
        if duplicateTotalString {
            _ = rodataString("getTotalSpace")
        }

        // Layout: helper stubs first, then the two call sequences.
        var text = [UInt32]()
        let textStart = textVaddr

        func emit(_ w: UInt32) -> UInt64 {
            let pc = textStart + UInt64(text.count * 4)
            text.append(w)
            return pc
        }

        // convertHelper / callStaticLongHelper stubs (targets of shared bls).
        let convertHelperEntry = textStart
        _ = emit(ret)
        let callStaticLongHelperEntry = textStart + 4
        _ = emit(ret)

        // getTotalSpace call site, mirroring the real code shape:
        // adrp/add the name and signature strings, GetStaticMethodID, string conversion,
        // then CallStaticLongMethodA — the instruction the patch replaces.
        var totalCallSite: UInt64 = 0
        if let total {
            _ = emit(adrp(rd: 2, targetVaddr: total.vaddr, pc: textStart + UInt64(text.count * 4)))
            _ = emit(addImm(rd: 2, rn: 2, imm12: UInt32(total.vaddr & 0xFFF)))
            _ = emit(adrp(rd: 3, targetVaddr: sig.vaddr, pc: textStart + UInt64(text.count * 4)))
            _ = emit(addImm(rd: 3, rn: 3, imm12: UInt32(sig.vaddr & 0xFFF)))
            _ = emit(0xaa16_03e0) // mov x0, x22
            _ = emit(0xd63f_0100) // blr x8 (GetMethodID vtable slot)
            _ = emit(0xaa00_03f8) // mov x24, x0
            _ = emit(0xaa15_03e0) // mov x0, x21
            let pcConvert = textStart + UInt64(text.count * 4)
            _ = emit(bl(pc: pcConvert, target: convertHelperEntry))
            _ = emit(0xf940_02e8) // ldr x8, [x23]
            _ = emit(0xd63f_0100) // blr x8 (NewStringUTF vtable slot)
            totalCallSite = textStart + UInt64(text.count * 4)
            let word: UInt32 = prePatched
                ? StorageQueryCompatibilityPatch.patchedInstruction
                : bl(pc: totalCallSite, target: callStaticLongHelperEntry)
            _ = emit(word)
            _ = emit(0xf900_0280) // str x0, [x20]
            _ = emit(ret)
            // The real call sites sit ~6.7 KB apart in separate functions; keep the
            // fixture's windows from overlapping the same way.
            for _ in 0..<(StorageQueryCompatibilityPatch.windowBytes / 4) {
                _ = emit(ret)
            }
        }

        // getUsableSpace call site with the same shape (never patched).
        _ = emit(adrp(rd: 2, targetVaddr: usable.vaddr, pc: textStart + UInt64(text.count * 4)))
        _ = emit(addImm(rd: 2, rn: 2, imm12: UInt32(usable.vaddr & 0xFFF)))
        _ = emit(adrp(rd: 3, targetVaddr: sig.vaddr, pc: textStart + UInt64(text.count * 4)))
        _ = emit(addImm(rd: 3, rn: 3, imm12: UInt32(sig.vaddr & 0xFFF)))
        _ = emit(0xaa17_03e0) // mov x0, x23
        _ = emit(0xd63f_0100) // blr x8
        let usableConvertPC = textStart + UInt64(text.count * 4)
        _ = emit(bl(pc: usableConvertPC, target: convertHelperEntry))
        let usableCallPC = textStart + UInt64(text.count * 4)
        _ = emit(bl(pc: usableCallPC, target: callStaticLongHelperEntry))
        _ = emit(0xf900_0280) // str x0, [x20]
        _ = emit(ret)

        let textData = text.reduce(into: Data()) { $0.appendLE($1) }
        // ELF header is 64 bytes; totalCallSite is 0 when the string was omitted.
        let expectedPatchOffset = totalCallSite >= textStart ? 64 + Int(totalCallSite - textStart) : 0

        // Section headers: 0 null, 1 .text, 2 .rodata, 3 .shstrtab
        var shstr = Data()
        func shstrOffset(_ s: String) -> UInt32 {
            let off = shstr.count
            shstr.append(Data(s.utf8))
            shstr.append(0)
            return UInt32(off)
        }
        _ = shstrOffset("")
        let textName = shstrOffset(".text")
        let rodataName = shstrOffset(".rodata")
        let shstrtabName = shstrOffset(".shstrtab")

        let textOffset = 64
        let rodataOffset = textOffset + textData.count
        let shstrOffsetValue = rodataOffset + rodata.count
        let shoff = shstrOffsetValue + shstr.count

        func shdr(nameOff: UInt32, type: UInt32, addr: UInt64, offset: Int, size: Int) -> Data {
            var d = Data()
            d.appendLE(nameOff)
            d.appendLE(type)
            d.appendLE(UInt64(0)) // flags
            d.appendLE(addr)
            d.appendLE(UInt64(offset))
            d.appendLE(UInt64(size))
            d.appendLE(UInt32(0)) // link
            d.appendLE(UInt32(0)) // info
            d.appendLE(UInt64(4)) // addralign
            d.appendLE(UInt64(0)) // entsize
            XCTAssertEqual(d.count, 64)
            return d
        }

        var out = Data([0x7f, UInt8(ascii: "E"), UInt8(ascii: "L"), UInt8(ascii: "F"), 2, 1, 1, 0])
        out.append(Data(repeating: 0, count: 64 - out.count))
        out.replaceSubrange(0x28..<0x30, with: LEBytes(UInt64(shoff)))
        out.replaceSubrange(0x3a..<0x3c, with: LEBytes(UInt16(64)))
        out.replaceSubrange(0x3c..<0x3e, with: LEBytes(UInt16(4)))
        out.replaceSubrange(0x3e..<0x40, with: LEBytes(UInt16(3)))
        out.append(textData)
        out.append(rodata)
        out.append(shstr)
        out.append(shdr(nameOff: 0, type: 0, addr: 0, offset: 0, size: 0))
        out.append(shdr(nameOff: textName, type: 1, addr: textVaddr, offset: textOffset, size: textData.count))
        out.append(shdr(nameOff: rodataName, type: 1, addr: rodataVaddr, offset: rodataOffset, size: rodata.count))
        out.append(shdr(nameOff: shstrtabName, type: 3, addr: 0, offset: shstrOffsetValue, size: shstr.count))
        return Fixture(data: out, expectedPatchOffset: expectedPatchOffset)
    }

    private func writeGameLib(_ data: Data) throws -> URL {
        let gameDir = tempDir.appendingPathComponent("game", isDirectory: true)
        let libDir = gameDir.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        try data.write(to: libDir.appendingPathComponent("libminecraftpe.so"))
        return gameDir
    }

    // MARK: - tests

    func testLocateFindsTotalSpaceCallSite() throws {
        let fixture = try XCTUnwrap(makeSyntheticGameLib())
        let elf = try XCTUnwrap(Elf64.parse(data: fixture.data))
        let site = StorageQueryCompatibilityPatch.locatePatchSite(data: fixture.data, elf: elf)
        guard case .success(let offset) = site else {
            return XCTFail("locate refused: \(site)")
        }
        XCTAssertEqual(offset, fixture.expectedPatchOffset)
    }

    func testPatchWritesStubAndBacksUpOriginal() throws {
        let fixture = try XCTUnwrap(makeSyntheticGameLib())
        let original = fixture.data
        let gameDir = try writeGameLib(original)
        let libDir = gameDir.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        let lib = libDir.appendingPathComponent("libminecraftpe.so")
        let backup = libDir.appendingPathComponent("libminecraftpe.so.orig")

        let report = StorageQueryCompatibilityPatch.patch(gameDirectory: gameDir)
        XCTAssertEqual(report.state, .patched, report.detail)

        let patched = try Data(contentsOf: lib)
        let stub = LEBytes(StorageQueryCompatibilityPatch.patchedInstruction)
        XCTAssertEqual(
            patched.subdata(in: fixture.expectedPatchOffset..<fixture.expectedPatchOffset + 4),
            stub
        )
        // Only the four patched bytes differ; the pristine copy is preserved.
        XCTAssertEqual(patched.count, original.count)
        var diffs = 0
        for i in 0..<patched.count where patched[i] != original[i] { diffs += 1 }
        XCTAssertEqual(diffs, 4)
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testPatchIsIdempotent() throws {
        let fixture = try XCTUnwrap(makeSyntheticGameLib())
        let gameDir = try writeGameLib(fixture.data)

        XCTAssertEqual(StorageQueryCompatibilityPatch.patch(gameDirectory: gameDir).state, .patched)
        let second = StorageQueryCompatibilityPatch.patch(gameDirectory: gameDir)
        XCTAssertEqual(second.state, .alreadyPatched, second.detail)
        let third = StorageQueryCompatibilityPatch.patch(gameDirectory: gameDir)
        XCTAssertEqual(third.state, .alreadyPatched)
    }

    func testPrePatchedLibraryIsDetected() throws {
        let fixture = try XCTUnwrap(makeSyntheticGameLib(prePatched: true))
        let elf = try XCTUnwrap(Elf64.parse(data: fixture.data))
        let site = StorageQueryCompatibilityPatch.locatePatchSite(data: fixture.data, elf: elf)
        guard case .success(let offset) = site else {
            return XCTFail("expected the stub slot, got \(site)")
        }
        XCTAssertEqual(offset, fixture.expectedPatchOffset)

        // Full patch() recognizes the stub without writing and installs the fast-path marker.
        let gameDir = try writeGameLib(fixture.data)
        let report = StorageQueryCompatibilityPatch.patch(gameDirectory: gameDir)
        XCTAssertEqual(report.state, .alreadyPatched, report.detail)
        let marker = gameDir
            .appendingPathComponent("lib/arm64-v8a/libminecraftpe.so.harbor-storage-ok")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // With the marker in place, the next run short-circuits without re-scanning.
        let fast = StorageQueryCompatibilityPatch.patch(gameDirectory: gameDir)
        XCTAssertEqual(fast.state, .alreadyPatched)
    }

    func testStaleMarkerFallsBackToFullScan() throws {
        let fixture = try XCTUnwrap(makeSyntheticGameLib())
        let gameDir = try writeGameLib(fixture.data)
        let libDir = gameDir.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        let lib = libDir.appendingPathComponent("libminecraftpe.so")
        let marker = libDir.appendingPathComponent("libminecraftpe.so.harbor-storage-ok")

        // A marker describing a different file (wrong size) must not be trusted.
        try "harbor-storage-patch-v1|4|999999|d2c02000\n".write(to: marker, atomically: true, encoding: .utf8)
        let report = StorageQueryCompatibilityPatch.patch(gameDirectory: gameDir)
        XCTAssertEqual(report.state, .patched, report.detail)
        XCTAssertEqual(try Data(contentsOf: lib).subdata(in: fixture.expectedPatchOffset..<fixture.expectedPatchOffset + 4), LEBytes(StorageQueryCompatibilityPatch.patchedInstruction))
    }

    func testMissingTotalStringIsNotNeeded() throws {
        let fixture = try XCTUnwrap(makeSyntheticGameLib(omitTotalString: true))
        let elf = try XCTUnwrap(Elf64.parse(data: fixture.data))
        let site = StorageQueryCompatibilityPatch.locatePatchSite(data: fixture.data, elf: elf)
        guard case .failure(let report) = site else {
            return XCTFail("expected refusal, got \(site)")
        }
        XCTAssertEqual(report.state, .notNeeded)
    }

    func testAmbiguousStringOccurrencesRefuse() throws {
        let fixture = try XCTUnwrap(makeSyntheticGameLib(duplicateTotalString: true))
        let elf = try XCTUnwrap(Elf64.parse(data: fixture.data))
        let site = StorageQueryCompatibilityPatch.locatePatchSite(data: fixture.data, elf: elf)
        guard case .failure(let report) = site else {
            return XCTFail("expected refusal, got \(site)")
        }
        XCTAssertEqual(report.state, .refused)
    }

    func testMissingLibraryIsNotNeeded() {
        let report = StorageQueryCompatibilityPatch.patch(
            gameDirectory: tempDir.appendingPathComponent("no-game", isDirectory: true)
        )
        XCTAssertEqual(report.state, .notNeeded)
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: UInt64) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

private func LEBytes(_ v: UInt32) -> Data {
    var le = v.littleEndian
    return Swift.withUnsafeBytes(of: &le) { Data($0) }
}

private func LEBytes(_ v: UInt16) -> Data {
    var le = v.littleEndian
    return Swift.withUnsafeBytes(of: &le) { Data($0) }
}

private func LEBytes(_ v: UInt64) -> Data {
    var le = v.littleEndian
    return Swift.withUnsafeBytes(of: &le) { Data($0) }
}
