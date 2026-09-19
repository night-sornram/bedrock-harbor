import Foundation
import HarborDomain
import HarborPlatform
import Testing
@testable import HarborApplication

@Suite("World archive service")
struct WorldArchiveServiceTests {
    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-worlds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A profileDataURL with one world written to disk.
    private func makeProfile(
        worlds: [(folder: String, name: String, utf16: Bool, extraFiles: [String: Data])] = []
    ) throws -> (root: URL, worldsURL: URL) {
        let base = try makeTempDir()
        let profile = base.appendingPathComponent("games/com.mojang", isDirectory: true)
        let worldsURL = profile.appendingPathComponent("minecraftWorlds", isDirectory: true)
        try FileManager.default.createDirectory(at: worldsURL, withIntermediateDirectories: true)
        for world in worlds {
            let dir = worldsURL.appendingPathComponent(world.folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeLevelName(world.name, utf16: world.utf16, to: dir)
            for (path, data) in world.extraFiles {
                let fileURL = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL)
            }
        }
        return (profile, worldsURL)
    }

    private func writeLevelName(_ name: String, utf16: Bool, to dir: URL) throws {
        let url = dir.appendingPathComponent("levelname.txt")
        let data: Data
        if utf16 {
            var encoded = Data([0xFF, 0xFE])
            encoded.append(name.data(using: .utf16LittleEndian) ?? Data())
            data = encoded
        } else {
            data = Data(name.utf8)
        }
        try data.write(to: url)
    }

    private func world(
        _ folder: String,
        name: String,
        utf16: Bool = false,
        extraFiles: [String: Data] = [:]
    ) -> (folder: String, name: String, utf16: Bool, extraFiles: [String: Data]) {
        (folder, name, utf16, extraFiles)
    }

    /// `unzip -Z1` entry listing of an archive (same tool the service uses).
    private func archiveEntries(_ archive: URL) async throws -> [String] {
        let result = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", archive.path],
            timeout: 30
        )
        guard result.exitCode == 0 else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    /// Minimal STORE-method zip built by hand — lets tests craft entries the
    /// zip CLI refuses to create (path traversal) without any dependency.
    private func makeZip(entries: [(name: String, data: Data)]) -> Data {
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        var body = Data()
        var central = Data()
        for entry in entries {
            let offset = body.count
            let nameBytes = Data(entry.name.utf8)
            body.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            body.append(u16(20)); body.append(u16(0)); body.append(u16(0))
            body.append(u16(0)); body.append(u16(0)); body.append(u32(0))
            body.append(u32(entry.data.count)); body.append(u32(entry.data.count))
            body.append(u16(nameBytes.count)); body.append(u16(0))
            body.append(nameBytes)
            body.append(entry.data)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(u16(20)); central.append(u16(20)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0)); central.append(u16(0)); central.append(u32(0))
            central.append(u32(entry.data.count)); central.append(u32(entry.data.count))
            central.append(u16(nameBytes.count)); central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0)); central.append(u32(0))
            central.append(u32(offset))
            central.append(nameBytes)
        }
        let centralOffset = body.count
        body.append(central)
        body.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        body.append(u16(0)); body.append(u16(0))
        body.append(u16(entries.count)); body.append(u16(entries.count))
        body.append(u32(central.count)); body.append(u32(centralOffset)); body.append(u16(0))
        return body
    }

    // MARK: - Listing

    @Test("listWorlds reads UTF-16LE and UTF-8 names, sizes, and sorts newest first")
    func listWorldsReadsNamesAndSizes() async throws {
        let (profile, worldsURL) = try makeProfile(worlds: [
            world("aaaaaaaa-0000", name: "Sky Block Fun", utf16: true, extraFiles: [
                "db/000001.log": Data("level-db-payload".utf8),
            ]),
            world("bbbbbbbb-0000", name: "Flatland", extraFiles: [
                "level.dat": Data(repeating: 7, count: 32),
            ]),
        ])
        let old = worldsURL.appendingPathComponent("aaaaaaaa-0000")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: old.path
        )

        let listed = await WorldArchiveService.listWorlds(profileDataURL: profile)

        #expect(listed.count == 2)
        #expect(listed[0].name == "Flatland") // newer first
        #expect(listed[1].name == "Sky Block Fun") // UTF-16LE + BOM decoded
        // "Sky Block Fun" = 13 UTF-16LE code units (26 bytes) + 2-byte BOM,
        // plus the 16-byte db payload.
        #expect(listed[1].byteSize == 26 + 2 + 16)
        #expect(listed.allSatisfy { $0.directoryURL.lastPathComponent == $0.id })
    }

    @Test("listWorlds on a profile without a minecraftWorlds directory is empty")
    func listWorldsWithoutDirectory() async throws {
        let base = try makeTempDir()
        let empty = await WorldArchiveService.listWorlds(profileDataURL: base)
        #expect(empty.isEmpty)
    }

    // MARK: - Export

    @Test("export packs world contents at the zip root, no AppleDouble junk")
    func exportProducesCleanMcworld() async throws {
        let (profile, _) = try makeProfile(worlds: [
            world("cccccccc-0000", name: "Export Me", extraFiles: [
                "level.dat": Data(repeating: 1, count: 16),
                "db/000002.log": Data("db-bytes".utf8),
            ]),
        ])
        let listed = await WorldArchiveService.listWorlds(profileDataURL: profile)
        let archive = try makeTempDir().appendingPathComponent("Export Me.mcworld")

        try await WorldArchiveService.exportWorld(listed[0], to: archive)

        let entries = try await archiveEntries(archive)
        #expect(entries.contains("levelname.txt"))
        #expect(entries.contains("level.dat"))
        #expect(entries.contains("db/000002.log"))
        #expect(!entries.contains { $0.hasPrefix("._") || $0.contains("__MACOSX") })
        // Contents at the root — not wrapped in a "cccccccc-0000/" folder.
        #expect(!entries.contains { $0.hasPrefix("cccccccc-0000/") })
    }

    @Test("export overwriting an existing file replaces it atomically")
    func exportOverwritesExisting() async throws {
        let (profile, _) = try makeProfile(worlds: [world("dddddddd-0000", name: "Again")])
        let listed = await WorldArchiveService.listWorlds(profileDataURL: profile)
        let dest = try makeTempDir().appendingPathComponent("Again.mcworld")
        try Data("stale".utf8).write(to: dest)

        try await WorldArchiveService.exportWorld(listed[0], to: dest)

        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64
        #expect(size ?? 0 > "stale".utf8.count)
    }

    @Test("sanitized file name strips path separators")
    func sanitizedFileName() async throws {
        let dirty = MinecraftWorld(
            id: "eeeeeeee-0000",
            name: "My/World: Two?",
            directoryURL: URL(fileURLWithPath: "/tmp"),
            modifiedAt: nil,
            byteSize: 0
        )
        let clean = WorldArchiveService.sanitizedFileName(for: dirty)
        #expect(!clean.contains("/") && !clean.contains(":") && !clean.contains("?"))
        #expect(clean.hasSuffix(".mcworld"))
    }

    // MARK: - Import

    @Test("export → import round-trip preserves name and world files")
    func importRoundTrip() async throws {
        let (source, _) = try makeProfile(worlds: [
            world("ffffffff-0000", name: "Round Trip", extraFiles: [
                "level.dat": Data(repeating: 3, count: 24),
                "db/000003.log": Data("round-trip-db".utf8),
            ]),
        ])
        let (dest, _) = try makeProfile()
        let archive = try makeTempDir().appendingPathComponent("Round Trip.mcworld")
        let original = await WorldArchiveService.listWorlds(profileDataURL: source)[0]
        try await WorldArchiveService.exportWorld(original, to: archive)

        let imported = try await WorldArchiveService.importWorld(from: archive, profileDataURL: dest)
        let listed = await WorldArchiveService.listWorlds(profileDataURL: dest)

        #expect(imported.name == "Round Trip")
        #expect(listed.count == 1)
        #expect(listed[0].name == "Round Trip")
        #expect(listed[0].id != "ffffffff-0000") // fresh folder, never overwrites
        let db = listed[0].directoryURL.appendingPathComponent("db/000003.log")
        #expect(try String(contentsOf: db, encoding: .utf8) == "round-trip-db")
    }

    @Test("import descends a single wrapping folder")
    func importDescendsWrappedFolder() async throws {
        // zip CLI wraps the world in "MyWorld/" — a common third-party layout.
        let stage = try makeTempDir()
        let wrapped = stage.appendingPathComponent("MyWorld", isDirectory: true)
        try FileManager.default.createDirectory(
            at: wrapped.appendingPathComponent("db", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeLevelName("Wrapped World", utf16: false, to: wrapped)
        try Data("w".utf8).write(to: wrapped.appendingPathComponent("db/000004.log"))
        let archive = stage.appendingPathComponent("wrapped.mcworld")
        _ = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-r", archive.lastPathComponent, "MyWorld"],
            currentDirectory: stage,
            timeout: 30
        )

        let (dest, _) = try makeProfile()
        let imported = try await WorldArchiveService.importWorld(from: archive, profileDataURL: dest)

        #expect(imported.name == "Wrapped World")
        #expect(FileManager.default.fileExists(
            atPath: imported.directoryURL.appendingPathComponent("db/000004.log").path
        ))
    }

    @Test("import accepts an extracted world folder directly")
    func importFromFolder() async throws {
        let (source, _) = try makeProfile(worlds: [world("11111111-0000", name: "Folder Source")])
        let original = await WorldArchiveService.listWorlds(profileDataURL: source)[0]
        let (dest, _) = try makeProfile()

        let imported = try await WorldArchiveService.importWorld(
            from: original.directoryURL,
            profileDataURL: dest
        )

        #expect(imported.name == "Folder Source")
        #expect(FileManager.default.fileExists(
            atPath: imported.directoryURL.appendingPathComponent("levelname.txt").path
        ))
        // Source stays untouched — import copies.
        #expect(FileManager.default.fileExists(atPath: original.directoryURL.path))
    }

    @Test("import rejects an archive with a path traversal entry")
    func importRejectsTraversal() async throws {
        let (dest, worldsURL) = try makeProfile()
        let malicious = makeZip(entries: [("../evil.txt", Data("boom".utf8))])
        let archive = try makeTempDir().appendingPathComponent("evil.mcworld")
        try malicious.write(to: archive)

        await #expect(throws: HarborError.self) {
            _ = try await WorldArchiveService.importWorld(from: archive, profileDataURL: dest)
        }
        // Nothing landed in minecraftWorlds.
        #expect(try FileManager.default.contentsOfDirectory(atPath: worldsURL.path).isEmpty)
    }

    @Test("import rejects an archive that is not a world")
    func importRejectsNonWorldArchive() async throws {
        let (dest, _) = try makeProfile()
        let archive = try makeTempDir().appendingPathComponent("readme.mcworld")
        try makeZip(entries: [("readme.txt", Data("hello".utf8))]).write(to: archive)

        await #expect(throws: HarborError.self) {
            _ = try await WorldArchiveService.importWorld(from: archive, profileDataURL: dest)
        }
    }

    @Test("import rejects an archive containing a symbolic link")
    func importRejectsSymlink() async throws {
        let stage = try makeTempDir()
        let worldDir = stage.appendingPathComponent("LinkWorld", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worldDir.appendingPathComponent("db", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeLevelName("Link World", utf16: false, to: worldDir)
        try FileManager.default.createSymbolicLink(
            at: worldDir.appendingPathComponent("db/sneaky"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        let archive = stage.appendingPathComponent("linked.mcworld")
        _ = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-r", "-y", archive.lastPathComponent, "LinkWorld"],
            currentDirectory: stage,
            timeout: 30
        )

        let (dest, _) = try makeProfile()
        await #expect(throws: HarborError.self) {
            _ = try await WorldArchiveService.importWorld(from: archive, profileDataURL: dest)
        }
    }

    @Test("import rejects a random folder")
    func importRejectsRandomFolder() async throws {
        let (dest, _) = try makeProfile()
        let junk = try makeTempDir()

        await #expect(throws: HarborError.self) {
            _ = try await WorldArchiveService.importWorld(from: junk, profileDataURL: dest)
        }
    }
}
