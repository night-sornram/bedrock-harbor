import Foundation

/// Fixes the false "Local storage is full. Manage worlds to make space." banner on
/// Bedrock 1.26.5x running on the mcpelauncher runtime (macos-builder v1.8.4-573).
///
/// Root cause (verified 2026-09-19 with Minecraft 1.26.51.1): the game reads device
/// storage through two static JNI methods on its MainActivity class —
/// `getTotalSpace(Ljava/lang/String;)J` and `getUsableSpace(Ljava/lang/String;)J`.
/// The launcher's fake JVM implements only `getUsableSpace` (hard-coded 1 TB); for the
/// missing `getTotalSpace` jnivm fabricates an unresolved method whose calls return the
/// default long value, 0. The game then computes its storage picture with total = 0
/// bytes and flags local storage as full even though the disk has plenty of space.
///
/// The patch replaces the `bl CallStaticLongMethodA` behind the getTotalSpace JNI call
/// with `mov x0, #0x10000000000` (1 TB) — the same fake capacity getUsableSpace already
/// reports, so used = total − free stays a sane 0. The call site is located structurally,
/// never by hard-coded offset: the single ADRP+ADD pair that materializes the
/// "getTotalSpace" string literal, then the last `bl` within its instruction window whose
/// target is shared with the equivalent "getUsableSpace" call window (the JNI call
/// sequence is GetStaticMethodID → string conversion → CallStaticLongMethod, so the
/// shared helper reached last is the call helper). Any ambiguity — duplicate strings,
/// multiple reference sites, no shared helper — refuses to patch. Idempotent; the
/// pristine library is preserved as `libminecraftpe.so.orig` next to the patched file
/// (deliberately not `.so.bck`, which `restorePatchedGameLibraries` treats as a restore
/// request on every launch).
public struct StorageQueryCompatibilityPatch: Sendable {

    public struct Report: Error, Sendable, Equatable {
        public var state: State
        public var detail: String

        public enum State: String, Sendable, Equatable {
            case patched
            case alreadyPatched
            case notNeeded
            case refused
            case failed
        }

        public init(state: State, detail: String) {
            self.state = state
            self.detail = detail
        }
    }

    public static let gameLibrarySubpath = "lib/arm64-v8a/libminecraftpe.so"

    /// `mov x0, #0x10000000000` (movz x0, #0x100, lsl #32) — 1 TB.
    static let patchedInstruction: UInt32 = 0xd2c0_2000

    /// Instruction window searched for the JNI call helper after each string reference
    /// (real 1.26.51.1 sites: 0x54/0x58 bytes from the ADRP to the call).
    static let windowBytes = 0x60

    static let totalSpaceSelector = Data("getTotalSpace\0".utf8)
    static let usableSpaceSelector = Data("getUsableSpace\0".utf8)

    public static func patch(gameDirectory: URL) -> Report {
        let fm = FileManager.default
        let lib = gameDirectory.appendingPathComponent(gameLibrarySubpath, isDirectory: false)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: lib.path, isDirectory: &isDir), !isDir.boolValue else {
            return Report(state: .notNeeded, detail: "no libminecraftpe.so in game package")
        }
        let marker = lib.appendingPathExtension("harbor-storage-ok")
        if let fast = fastAlreadyPatched(lib: lib, marker: marker) {
            return fast
        }
        guard let data = try? Data(contentsOf: lib, options: [.mappedIfSafe]) else {
            return Report(state: .failed, detail: "unreadable libminecraftpe.so")
        }
        guard let elf = Elf64.parse(data: data) else {
            return Report(state: .refused, detail: "libminecraftpe.so is not a parseable ELF64")
        }

        let site: Int
        switch locatePatchSite(data: data, elf: elf) {
        case .success(let offset):
            site = offset
        case .failure(let report):
            return report
        }

        // Bytes already in place (patched by an earlier run whose marker is gone)?
        var probe = patchedInstruction.littleEndian
        let probeBytes = withUnsafeBytes(of: &probe) { Data($0) }
        if data.subdata(in: site..<site + 4) == probeBytes {
            writeMarker(marker, site: site, fileSize: data.count)
            return Report(state: .alreadyPatched, detail: "getTotalSpace call already stubbed at file offset 0x\(String(site, radix: 16))")
        }

        let backup = lib.deletingPathExtension().appendingPathExtension("so.orig")
        do {
            if !fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: lib, to: backup)
            }
            let handle = try FileHandle(forWritingTo: lib)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(site))
            var stub = patchedInstruction.littleEndian
            try withUnsafeBytes(of: &stub) { try handle.write(contentsOf: Data($0)) }
        } catch {
            return Report(state: .failed, detail: "write failed: \(error.localizedDescription)")
        }

        // Read back through a fresh handle; the scan mapping may be stale after the write.
        guard let verify = try? FileHandle(forReadingFrom: lib) else {
            return Report(state: .failed, detail: "could not verify patched bytes")
        }
        defer { try? verify.close() }
        try? verify.seek(toOffset: UInt64(site))
        guard let read = try? verify.read(upToCount: 4) else {
            return Report(state: .failed, detail: "could not verify patched bytes")
        }
        var expected = patchedInstruction.littleEndian
        let expectedBytes = withUnsafeBytes(of: &expected) { Data($0) }
        guard read == expectedBytes else {
            return Report(state: .failed, detail: "patched bytes did not stick at offset \(String(site, radix: 16))")
        }
        writeMarker(marker, site: site, fileSize: data.count)
        return Report(state: .patched, detail: "getTotalSpace call → 1 TB stub at file offset 0x\(String(site, radix: 16))")
    }

    // MARK: - Launch fast path

    /// The full locate scan walks ~300 MB of .text (~13 s). A completed patch leaves a marker
    /// (patch offset + file size + instruction) so later launches confirm the patch with one
    /// 4-byte read instead. A marker that does not match falls through to the full scan, so a
    /// re-imported or updated game library is re-patched normally.
    static let markerHeader = "harbor-storage-patch-v1"

    private static func fastAlreadyPatched(lib: URL, marker: URL) -> Report? {
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 4, parts[0] == markerHeader,
              let site = Int(parts[1]), let size = Int(parts[2]),
              let word = UInt32(parts[3], radix: 16)
        else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: lib.path),
              let fileSize = attrs[.size] as? Int, fileSize == size
        else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: lib) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(site))
        guard let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else { return nil }
        var expected = word.littleEndian
        let expectedBytes = withUnsafeBytes(of: &expected) { Data($0) }
        guard bytes == expectedBytes else { return nil }
        return Report(state: .alreadyPatched, detail: "getTotalSpace call already stubbed (marker)")
    }

    private static func writeMarker(_ marker: URL, site: Int, fileSize: Int) {
        let text = "\(markerHeader)|\(site)|\(fileSize)|\(String(patchedInstruction, radix: 16))\n"
        try? text.write(to: marker, atomically: true, encoding: .utf8)
    }

    // MARK: - Site location (pure)

    static func locatePatchSite(data: Data, elf: Elf64) -> Result<Int, Report> {
        guard let text = elf.section(".text"), text.address != 0, text.size >= 8 else {
            return .failure(Report(state: .refused, detail: "no usable .text section"))
        }

        let totalVaddr: Int
        switch uniqueVaddr(of: totalSpaceSelector, data: data, elf: elf, what: "getTotalSpace") {
        case .success(let v): totalVaddr = v
        case .failure(let report): return .failure(report)
        }
        let usableVaddr: Int
        switch uniqueVaddr(of: usableSpaceSelector, data: data, elf: elf, what: "getUsableSpace") {
        case .success(let v): usableVaddr = v
        case .failure(let report): return .failure(report)
        }

        let totalRefs = adrpAddReferences(data: data, text: text, target: totalVaddr)
        guard totalRefs.count == 1 else {
            return .failure(Report(state: .refused, detail: "expected 1 getTotalSpace reference, found \(totalRefs.count)"))
        }
        let usableRefs = adrpAddReferences(data: data, text: text, target: usableVaddr)
        guard usableRefs.count == 1 else {
            return .failure(Report(state: .refused, detail: "expected 1 getUsableSpace reference, found \(usableRefs.count)"))
        }

        let totalWindow = branchInstructions(data: data, text: text, from: totalRefs[0], windowBytes: windowBytes)
        let usableWindow = branchInstructions(data: data, text: text, from: usableRefs[0], windowBytes: windowBytes)

        // The two call sites live in separate functions (≈6.7 KB apart in 1.26.51.1).
        // Overlapping windows would let one site's calls satisfy the other's matching —
        // refuse rather than risk patching the wrong branch.
        let totalRange = totalRefs[0]..<totalRefs[0] &+ windowBytes
        let usableRange = usableRefs[0]..<usableRefs[0] &+ windowBytes
        guard !totalRange.overlaps(usableRange) else {
            return .failure(Report(state: .refused, detail: "call-site windows overlap"))
        }

        // Already patched: our stub sitting anywhere in the total-space window means a
        // previous run replaced the call; checked first because the stub removes the very
        // branch this locator would otherwise key on. The stub's slot is returned so the
        // caller can confirm the bytes and refresh its fast-path marker.
        if let stubIndex = totalWindow.words.firstIndex(of: patchedInstruction) {
            return .success(totalRefs[0] + stubIndex * 4)
        }

        guard let lastSharedTotal = lastSharedBranch(totalWindow, usableWindow),
              let lastSharedUsable = lastSharedBranch(usableWindow, totalWindow),
              lastSharedTotal.target == lastSharedUsable.target
        else {
            return .failure(Report(state: .refused, detail: "no shared CallStaticLong helper in call-site windows"))
        }
        return .success(lastSharedTotal.offset)
    }

    private enum StringLookup {
        case success(Int)
        case failure(Report)
    }

    /// Exactly one occurrence of `bytes` in the file, mapped to its virtual address.
    private static func uniqueVaddr(of bytes: Data, data: Data, elf: Elf64, what: String) -> StringLookup {
        var offsets: [Int] = []
        var searchStart = data.startIndex
        while let range = data.firstRange(of: bytes, in: searchStart..<data.endIndex) {
            offsets.append(range.lowerBound)
            searchStart = range.lowerBound + 1
            if offsets.count > 1 { break }
        }
        guard !offsets.isEmpty else {
            return .failure(Report(state: .notNeeded, detail: "\(what) not present; nothing to patch"))
        }
        guard offsets.count == 1 else {
            return .failure(Report(state: .refused, detail: "\(what) occurs \(offsets.count) times"))
        }
        guard let vaddr = elf.vaddr(data: data, fileOffset: offsets[0]) else {
            return .failure(Report(state: .refused, detail: "\(what) not inside a mapped section"))
        }
        return .success(vaddr)
    }

    /// File offsets (of the ADRP) of ADRP+ADD-immediate pairs in .text that compute `target`.
    private static func adrpAddReferences(data: Data, text: Elf64.Section, target: Int) -> [Int] {
        data.withUnsafeBytes { raw in
            var refs: [Int] = []
            let end = text.offset + text.size
            var i = text.offset
            while i + 8 <= end {
                let i1 = raw.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian
                let i2 = raw.loadUnaligned(fromByteOffset: i + 4, as: UInt32.self).littleEndian
                if (i1 & 0x9F00_0000) == 0x9000_0000, (i2 & 0xFFC0_0000) == 0x9100_0000,
                   (i1 & 0x1F) == (i2 & 0x1F) {
                    let immlo = Int(i1 >> 29) & 0x3
                    let immhi = Int(i1 >> 5) & 0x7FFFF
                    var imm = (immhi << 2) | immlo
                    if imm & (1 << 20) != 0 { imm -= 1 << 21 }
                    let pcPage = (text.address + (i - text.offset)) & ~0xFFF
                    let addImm = Int(i2 >> 10) & 0xFFF
                    if pcPage + (imm << 12) + addImm == target {
                        refs.append(i)
                    }
                }
                i += 4
            }
            return refs
        }
    }

    private struct Branch {
        var offset: Int
        var target: Int
    }

    private struct Window {
        var branches: [Branch]
        var words: [UInt32]
    }

    /// `bl` instructions (file offset + virtual target) in the window after `from`,
    /// plus every aligned instruction word in the window for stub detection.
    private static func branchInstructions(data: Data, text: Elf64.Section, from fileOffset: Int, windowBytes: Int) -> Window {
        data.withUnsafeBytes { raw in
            var branches: [Branch] = []
            var words: [UInt32] = []
            let end = min(fileOffset + windowBytes, text.offset + text.size)
            var i = fileOffset
            while i + 4 <= end {
                let w = raw.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian
                words.append(w)
                if (w & 0xFC00_0000) == 0x9400_0000 {
                    var off = Int(w & 0x3FF_FFFF)
                    if off & (1 << 25) != 0 { off -= 1 << 26 }
                    let pc = text.address + (i - text.offset)
                    branches.append(Branch(offset: i, target: pc + off * 4))
                }
                i += 4
            }
            return Window(branches: branches, words: words)
        }
    }

    /// The last branch in `window` whose target also appears in `other`.
    private static func lastSharedBranch(_ window: Window, _ other: Window) -> Branch? {
        let otherTargets = Set(other.branches.map(\.target))
        return window.branches.last { otherTargets.contains($0.target) }
    }
}

// MARK: - vaddr mapping

extension Elf64 {
    /// Virtual address for a file offset, via the section that contains it.
    func vaddr(data: Data, fileOffset: Int) -> Int? {
        for s in sections where s.type != 8 && s.address != 0 {
            if s.offset <= fileOffset, fileOffset < s.offset + s.size {
                return s.address + (fileOffset - s.offset)
            }
        }
        return nil
    }
}
