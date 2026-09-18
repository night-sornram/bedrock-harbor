import Foundation

/// Repairs a hash-table bug in the macOS bionic libc shim shipped with mcpelauncher
/// (macos-builder v1.8.4-573): the build appends a real `pthread_sigmask` implementation to
/// `.dynsym` without registering it in the GNU/SysV hash tables, so dynamic lookups cannot
/// find it and Bedrock 1.26.50+ fails to load with `cannot locate symbol "pthread_sigmask"`
/// (upstream: minecraft-linux/mcpelauncher-manifest issue #2030).
///
/// The repair mirrors in file form what mcpelauncher-updates does at runtime via
/// `mcpelauncher_relocate`: it repurposes one unused, hash-reachable `.dynsym` entry inside
/// the target symbol's GNU-hash bucket run — copying the `pthread_sigmask` entry over it,
/// rewriting the run's chain word, and setting the bloom-filter bits. The victim must be an
/// internal llvm-libc constant with no relocations referencing it; the patch refuses to touch
/// any build whose preconditions do not hold exactly. Idempotent, with the pristine original
/// preserved as `libc.so.orig` next to the patched file.
public struct GuestLibcCompatibilityPatch: Sendable {

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

    public static let guestLibcSubpath = "Resources/mcpelauncher/lib/arm64-v8a/libc.so"
    static let targetSymbol = "pthread_sigmask"

    /// Names that are safe to repurpose: internal llvm-libc constants/typeinfo that nothing
    /// imports and no relocation references (verified against v1.8.4-573 and the game libs).
    static let safeVictimPrefixes = [
        "_ZZN11__llvm_libc", // function-local static constants (inf_string, DECIMAL_POINT, …)
        "_ZTS",              // typeinfo name bytes
        "_ZTI",              // typeinfo objects
    ]

    public static func patch(runtimeRoot: URL) -> Report {
        let fm = FileManager.default
        let libc = runtimeRoot.appendingPathComponent(guestLibcSubpath, isDirectory: false)
        let original = libc.deletingLastPathComponent().appendingPathComponent("libc.so.orig", isDirectory: false)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: libc.path, isDirectory: &isDir), !isDir.boolValue else {
            return Report(state: .failed, detail: "guest libc missing at \(libc.path)")
        }
        guard var data = try? Data(contentsOf: libc) else {
            return Report(state: .failed, detail: "unreadable guest libc")
        }
        guard let elf = Elf64.parse(data: data) else {
            return Report(state: .refused, detail: "guest libc is not a parseable ELF64")
        }

        switch Self.repair(elf: elf, data: &data) {
        case .success(let detail):
            do {
                if !fm.fileExists(atPath: original.path) {
                    try Data(contentsOf: libc).write(to: original) // pristine copy before first patch
                }
                try data.write(to: libc, options: .atomic)
                return Report(state: .patched, detail: detail)
            } catch {
                return Report(state: .failed, detail: "write failed: \(error.localizedDescription)")
            }
        case .failure(let report):
            return report
        }
    }

    static func repair(elf: Elf64, data: inout Data) -> Result<String, Report> {
        guard let dynsym = elf.section(".dynsym"),
              let dynstr = elf.section(".dynstr"),
              let gnuHash = elf.section(".gnu.hash")
        else {
            return .failure(Report(state: .refused, detail: "dynsym/dynstr/.gnu.hash missing"))
        }

        func symbolName(_ index: Int) -> String? {
            let nameOffset = elf.readU32(data: data, offset: dynsym.offset + index * 24)
            guard let nameOffset else { return nil }
            return elf.string(data: data, strtab: dynstr, offset: Int(nameOffset))
        }

        guard let target = elf.findSymbol(data: data, name: targetSymbol) else {
            return .failure(Report(state: .notNeeded, detail: "\(targetSymbol) not present; nothing to repair"))
        }
        guard target.value != 0, target.shndx != 0 else {
            return .failure(Report(state: .refused, detail: "\(targetSymbol) present but not defined here"))
        }

        guard let gnu = GnuHash.parse(data: data, section: gnuHash, dynsymCount: dynsym.size / 24) else {
            return .failure(Report(state: .refused, detail: "unparseable .gnu.hash"))
        }
        if gnu.lookup(data: data, elf: elf, dynsym: dynsym, dynstr: dynstr, name: targetSymbol) != nil {
            return .failure(Report(state: .alreadyPatched, detail: "\(targetSymbol) already hash-reachable"))
        }

        // Victim must sit in the target's bucket run, be defined, unreferenced by
        // relocations, and match the safe-name allowlist.
        let targetHash = GnuHash.hash(targetSymbol)
        guard let run = gnu.bucketRun(data: data, hash: targetHash) else {
            return .failure(Report(state: .refused, detail: "empty bucket for \(targetSymbol)"))
        }
        let referenced = elf.relocationSymbolIndices(data: data)
        guard let victim = run.first(where: { index in
            index != target.index
                && !referenced.contains(index)
                && (elf.symbol(data: data, index: index)?.shndx ?? 0) != 0
                && (symbolName(index).map { name in Self.safeVictimPrefixes.contains { name.hasPrefix($0) } } ?? false)
        }), let victimName = symbolName(victim) else {
            return .failure(Report(state: .refused, detail: "no safe victim symbol in bucket run"))
        }

        // 1) dynsym: victim entry becomes a copy of the target entry.
        let entryOffset = dynsym.offset + victim * 24
        let targetEntryOffset = dynsym.offset + target.index * 24
        let targetEntry = data.subdata(in: targetEntryOffset..<targetEntryOffset + 24)
        data.replaceSubrange(entryOffset..<entryOffset + 24, with: targetEntry)

        // 2) gnu chain: victim slot carries the target hash (lsb clear; victim is mid-run).
        let chainOffset = gnu.chainOffset + (victim - gnu.symbolOffset) * 4
        data.replaceBytes(offset: chainOffset, value: UInt32(targetHash & ~1))

        // 3) bloom filter bits for the target hash.
        let (wordIndex, mask) = GnuHash.bloomBits(hash: targetHash, bloomSize: gnu.bloomSize, bloomShift: gnu.bloomShift)
        let bloomWordOffset = gnu.bloomOffset + wordIndex * 8
        if let word = elf.readU64(data: data, offset: bloomWordOffset) {
            data.replaceBytes(offset: bloomWordOffset, value: word | mask)
        }

        return .success("repurposed \(victimName) (dynsym \(victim)) for \(targetSymbol) (dynsym \(target.index))")
    }
}

// MARK: - Minimal ELF64 little-endian reader/writer over Data

public struct Elf64: Sendable {
    public struct Section: Sendable {
        public var name: String
        public var type: UInt32
        public var offset: Int
        public var size: Int
    }

    public struct Symbol: Sendable {
        public var index: Int
        public var name: String
        public var value: UInt64
        public var size: UInt64
        public var shndx: UInt16
    }

    public private(set) var sections: [Section] = []

    public static func parse(data: Data) -> Elf64? {
        guard data.count > 64 else { return nil }
        guard data[0] == 0x7f, data[1] == UInt8(ascii: "E"), data[2] == UInt8(ascii: "L"), data[3] == UInt8(ascii: "F") else {
            return nil
        }
        let classByte = data[4]
        let endian = data[5]
        guard classByte == 2, endian == 1 else { return nil } // ELF64 little-endian

        func u16(_ off: Int) -> Int { Int(data[off]) | Int(data[off + 1]) << 8 }
        func u32(_ off: Int) -> Int {
            Int(data[off]) | Int(data[off + 1]) << 8 | Int(data[off + 2]) << 16 | Int(data[off + 3]) << 24
        }
        func u64(_ off: Int) -> Int {
            var v = 0
            for i in (0..<8).reversed() { v = v << 8 | Int(data[off + i]) }
            return v
        }

        let shoff = u64(0x28)
        let shentsize = u16(0x3a)
        let shnum = u16(0x3c)
        let shstrndx = u16(0x3e)
        guard shoff > 0, shentsize >= 64, shnum > 0, shstrndx < shnum,
              shoff + shnum * shentsize <= data.count
        else { return nil }

        func sectionHeader(_ i: Int) -> (nameOff: Int, type: Int, offset: Int, size: Int)? {
            let base = shoff + i * shentsize
            guard base + 64 <= data.count else { return nil }
            return (u32(base), u32(base + 4), u64(base + 0x18), u64(base + 0x20))
        }
        guard let strtabHeader = sectionHeader(shstrndx) else { return nil }
        func sectionName(_ nameOff: Int) -> String {
            let start = strtabHeader.offset + nameOff
            guard start < data.count else { return "" }
            var end = start
            while end < data.count, data[end] != 0 { end += 1 }
            return String(data: data[start..<end], encoding: .utf8) ?? ""
        }

        var elf = Elf64()
        for i in 0..<shnum {
            guard let h = sectionHeader(i) else { return nil }
            elf.sections.append(Section(name: sectionName(h.nameOff), type: UInt32(h.type), offset: h.offset, size: h.size))
        }
        return elf
    }

    public func section(_ name: String) -> Section? {
        sections.first { $0.name == name }
    }

    public func readU32(data: Data, offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return UInt32(littleEndian: v)
    }

    public func readU64(data: Data, offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
        return UInt64(littleEndian: v)
    }

    public func string(data: Data, strtab: Section, offset: Int) -> String? {
        let start = strtab.offset + offset
        guard start >= 0, start < data.count else { return nil }
        var end = start
        while end < data.count, data[end] != 0 { end += 1 }
        return String(data: data[start..<end], encoding: .utf8)
    }

    public func symbol(data: Data, index: Int) -> Symbol? {
        guard let dynsym = section(".dynsym"), let dynstr = section(".dynstr") else { return nil }
        let base = dynsym.offset + index * 24
        guard base + 24 <= dynsym.offset + dynsym.size else { return nil }
        guard let nameOff = readU32(data: data, offset: base) else { return nil }
        let shndxRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 6, as: UInt16.self) }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 8, as: UInt64.self) }
        let size = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 16, as: UInt64.self) }
        return Symbol(
            index: index,
            name: string(data: data, strtab: dynstr, offset: Int(UInt32(littleEndian: nameOff))) ?? "",
            value: UInt64(littleEndian: value),
            size: UInt64(littleEndian: size),
            shndx: UInt16(littleEndian: shndxRaw)
        )
    }

    public func findSymbol(data: Data, name: String) -> Symbol? {
        guard let dynsym = section(".dynsym") else { return nil }
        let count = dynsym.size / 24
        for i in 0..<count {
            if let s = symbol(data: data, index: i), s.name == name {
                return s
            }
        }
        return nil
    }

    /// Symbol indices referenced by .rela.dyn / .rela.plt relocations.
    public func relocationSymbolIndices(data: Data) -> Set<Int> {
        var indices = Set<Int>()
        for name in [".rela.dyn", ".rela.plt"] {
            guard let s = section(name) else { continue }
            var off = s.offset
            let end = min(s.offset + s.size, data.count)
            while off + 24 <= end {
                let info = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 8, as: UInt64.self) }
                indices.insert(Int(UInt64(littleEndian: info) >> 32))
                off += 24
            }
        }
        return indices
    }
}

// MARK: - GNU hash table

struct GnuHash: Sendable {
    let headerOffset: Int
    let nbuckets: Int
    let symbolOffset: Int
    let bloomSize: Int
    let bloomShift: Int
    let bloomOffset: Int
    let bucketsOffset: Int
    let chainOffset: Int

    static func hash(_ name: String) -> UInt32 {
        var h: UInt32 = 5381
        for byte in name.utf8 {
            h = h &* 33 &+ UInt32(byte)
        }
        return h
    }

    static func parse(data: Data, section: Elf64.Section, dynsymCount: Int) -> GnuHash? {
        guard section.size >= 16 else { return nil }
        func u32(_ off: Int) -> UInt32? {
            guard off >= 0, off + 4 <= data.count else { return nil }
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
            return UInt32(littleEndian: v)
        }
        guard let nb = u32(section.offset),
              let symoff = u32(section.offset + 4),
              let bloomSize = u32(section.offset + 8),
              let bloomShift = u32(section.offset + 12)
        else { return nil }
        let bloomOffset = section.offset + 16
        let bucketsOffset = bloomOffset + Int(bloomSize) * 8
        let chainOffset = bucketsOffset + Int(nb) * 4
        guard Int(symoff) <= dynsymCount else { return nil }
        return GnuHash(
            headerOffset: section.offset,
            nbuckets: Int(nb),
            symbolOffset: Int(symoff),
            bloomSize: Int(bloomSize),
            bloomShift: Int(bloomShift),
            bloomOffset: bloomOffset,
            bucketsOffset: bucketsOffset,
            chainOffset: chainOffset
        )
    }

    static func bloomBits(hash: UInt32, bloomSize: Int, bloomShift: Int) -> (wordIndex: Int, mask: UInt64) {
        let wordIndex = Int(hash / 64) % max(bloomSize, 1)
        let mask: UInt64 = (1 &<< UInt64(hash % 64)) | (1 &<< UInt64((hash >> UInt32(bloomShift)) % 64))
        return (wordIndex, mask)
    }

    /// Contiguous symbol-index run for the given hash's bucket.
    func bucketRun(data: Data, hash: UInt32) -> [Int]? {
        guard nbuckets > 0 else { return nil }
        func u32(_ off: Int) -> UInt32? {
            guard off >= 0, off + 4 <= data.count else { return nil }
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
            return UInt32(littleEndian: v)
        }
        guard let start = u32(bucketsOffset + Int(hash % UInt32(nbuckets)) * 4), start != 0 else { return nil }
        var run: [Int] = []
        var idx = Int(start)
        while true {
            run.append(idx)
            guard let chain = u32(chainOffset + (idx - symbolOffset) * 4) else { break }
            if chain & 1 == 1 { break }
            idx += 1
            if run.count > dynsymCap { break }
        }
        return run
    }

    func lookup(data: Data, elf: Elf64, dynsym: Elf64.Section, dynstr: Elf64.Section, name: String) -> Int? {
        let h = Self.hash(name)
        guard let run = bucketRun(data: data, hash: h) else { return nil }
        let (wordIndex, mask) = Self.bloomBits(hash: h, bloomSize: bloomSize, bloomShift: bloomShift)
        if let word = elf.readU64(data: data, offset: bloomOffset + wordIndex * 8), word & mask != mask {
            return nil
        }
        for idx in run {
            guard let sym = elf.symbol(data: data, index: idx) else { continue }
            if sym.name == name { return idx }
        }
        return nil
    }

    private var dynsymCap: Int { 100_000 }
}

// MARK: - Data byte helpers

private extension Data {
    mutating func replaceBytes(offset: Int, value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { buffer in
            for (i, byte) in buffer.enumerated() {
                self[offset + i] = byte
            }
        }
    }

    mutating func replaceBytes(offset: Int, value: UInt64) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { buffer in
            for (i, byte) in buffer.enumerated() {
                self[offset + i] = byte
            }
        }
    }
}
