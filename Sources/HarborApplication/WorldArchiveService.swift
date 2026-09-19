import Foundation
import HarborDomain
import HarborPlatform

// MARK: - Model

/// One Minecraft world ("map") living under a profile's
/// `games/com.mojang/minecraftWorlds` directory.
public struct MinecraftWorld: Identifiable, Sendable, Equatable {
    /// World folder name — a UUID-ish string chosen by the game.
    public let id: String
    /// Display name from `levelname.txt`.
    public let name: String
    public let directoryURL: URL
    public let modifiedAt: Date?
    public let byteSize: Int64

    public init(
        id: String,
        name: String,
        directoryURL: URL,
        modifiedAt: Date?,
        byteSize: Int64
    ) {
        self.id = id
        self.name = name
        self.directoryURL = directoryURL
        self.modifiedAt = modifiedAt
        self.byteSize = byteSize
    }

    /// Byte size formatted the way the Worlds list shows it.
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

// MARK: - Service

/// Exports and imports Minecraft worlds as standard `.mcworld` archives
/// (zip with the world folder's *contents* at the root — the convention every
/// Bedrock platform accepts). No AppKit: panels live in the features layer.
///
/// Archive work uses the system tools through `HarborSubprocess`, matching the
/// CompatibilityPatches pattern: `ditto -c -k --norsrc --noextattr` to create
/// (verified to put contents at the root without AppleDouble `._*` entries)
/// and `ditto -x -k` to extract. Before any extraction, every entry name is
/// listed with `unzip -Z1` and validated with the hardened
/// `ArchivePathPolicy` so a hostile archive can never traverse out of staging.
public enum WorldArchiveService {
    public static let mcworldExtension = "mcworld"

    /// `…/games/com.mojang/minecraftWorlds` for a profile's data root.
    public static func worldsDirectory(profileDataURL: URL) -> URL {
        profileDataURL.appendingPathComponent("minecraftWorlds", isDirectory: true)
    }

    /// Every world under the profile's data root, newest-modified first.
    /// Async + nonisolated so the recursive size walk never runs on MainActor.
    public static func listWorlds(profileDataURL: URL) async -> [MinecraftWorld] {
        let dir = worldsDirectory(profileDataURL: profileDataURL)
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var worlds: [MinecraftWorld] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = readWorldName(directory: entry) ?? entry.lastPathComponent
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            worlds.append(
                MinecraftWorld(
                    id: entry.lastPathComponent,
                    name: name,
                    directoryURL: entry,
                    modifiedAt: modified,
                    byteSize: directorySize(entry)
                )
            )
        }
        worlds.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        return worlds
    }

    /// Archives the world's contents to `destination` (`.mcworld`). The zip is
    /// built in a temp file and moved into place, so a failure never leaves a
    /// half-written archive behind.
    public static func exportWorld(_ world: MinecraftWorld, to destination: URL) async throws {
        let fm = FileManager.default
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-world-export-\(UUID().uuidString).\(mcworldExtension)")
        defer { try? fm.removeItem(at: temp) }
        let result = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--norsrc", "--noextattr", world.directoryURL.path, temp.path],
            timeout: 600
        )
        guard result.exitCode == 0, !result.timedOut else {
            throw HarborError.archiveRejected(
                reason: "ditto could not pack “\(world.name)” (exit \(result.exitCode))"
            )
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: temp, to: destination)
        }
    }

    /// Imports a `.mcworld`/`.zip` archive or an already-extracted world
    /// folder into the profile's `minecraftWorlds`. The world always lands in
    /// a fresh folder — an existing world is never overwritten. Returns the
    /// imported world.
    @discardableResult
    public static func importWorld(
        from source: URL,
        profileDataURL: URL,
        stagingRoot: URL = FileManager.default.temporaryDirectory
    ) async throws -> MinecraftWorld {
        let worldsDir = worldsDirectory(profileDataURL: profileDataURL)
        let fm = FileManager.default
        try fm.createDirectory(at: worldsDir, withIntermediateDirectories: true)

        let staging = stagingRoot
            .appendingPathComponent("harbor-world-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let isArchive = ["mcworld", "zip", "mctemplate"].contains(
            source.pathExtension.lowercased()
        )
        let candidate: URL
        if isArchive {
            candidate = try await extractValidatedArchive(source, into: staging)
        } else if hasWorldMarker(source) {
            candidate = source
        } else {
            throw HarborError.archiveRejected(
                reason: "Not a Minecraft world — pick a .mcworld file or a world folder."
            )
        }

        let destination = worldsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.copyItem(at: candidate, to: destination)
        let name = readWorldName(directory: destination) ?? destination.lastPathComponent
        let modified = (try? destination.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return MinecraftWorld(
            id: destination.lastPathComponent,
            name: name,
            directoryURL: destination,
            modifiedAt: modified,
            byteSize: directorySize(destination)
        )
    }

    /// Default file name for the export save panel: `My World.mcworld`.
    public static func sanitizedFileName(for world: MinecraftWorld) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var cleaned = world.name
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = world.id }
        return "\(cleaned).\(mcworldExtension)"
    }

    // MARK: - Archive handling

    /// Lists the archive's entries, validates every path against the hardened
    /// `ArchivePathPolicy`, extracts into staging, and returns the world
    /// directory inside it — descending a single wrapping folder if present.
    private static func extractValidatedArchive(_ archive: URL, into staging: URL) async throws -> URL {
        let listing = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", archive.path],
            timeout: 60
        )
        guard listing.exitCode == 0, !listing.timedOut else {
            throw HarborError.archiveRejected(reason: "The archive could not be read — it may be corrupt.")
        }
        let entries = listing.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        for entry in entries {
            let decision = ArchivePathPolicy.evaluateEntryPath(entry)
            if !decision.isAccepted {
                throw HarborError.archiveRejected(
                    reason: "The archive contains an unsafe path and was rejected."
                )
            }
        }

        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let result = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, extracted.path],
            timeout: 600
        )
        guard result.exitCode == 0, !result.timedOut else {
            throw HarborError.archiveRejected(
                reason: "The world could not be unpacked (ditto exit \(result.exitCode))."
            )
        }
        // `-Z1` cannot see symlink entries, and `ArchivePathPolicy` forbids
        // them in game/content archives — sweep the extracted tree instead so
        // one can never be copied into minecraftWorlds.
        if containsSymlink(extracted) {
            throw HarborError.archiveRejected(
                reason: "The archive contains a symbolic link and was rejected."
            )
        }

        if hasWorldMarker(extracted) { return extracted }
        // Some tools wrap the world in one folder (`MyWorld/levelname.txt`).
        let children = ((try? fm.contentsOfDirectory(
            at: extracted,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { entry in
            !entry.lastPathComponent.hasPrefix("__MACOSX")
        }
        if children.count == 1, hasWorldMarker(children[0]) {
            return children[0]
        }
        throw HarborError.archiveRejected(
            reason: "This does not look like a Minecraft world (no levelname.txt / level.dat / db)."
        )
    }

    // MARK: - World introspection

    /// Bedrock writes `levelname.txt` as UTF-16LE (with BOM) in older
    /// versions and plain UTF-8 in newer ones — accept both.
    public static func readWorldName(directory: URL) -> String? {
        let url = directory.appendingPathComponent("levelname.txt")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            return clean(String(data: data, encoding: .utf16LittleEndian) ?? "")
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            return clean(String(data: data, encoding: .utf16BigEndian) ?? "")
        }
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
            return clean(utf8)
        }
        // BOM-less UTF-16LE: lots of NUL bytes in an ASCII-ish payload.
        let nulCount = data.lazy.filter { $0 == 0 }.count
        if data.count % 2 == 0, nulCount > data.count / 4,
           let utf16 = String(data: data, encoding: .utf16LittleEndian) {
            return clean(utf16)
        }
        return nil
    }

    /// A directory is treated as a world when it carries any Bedrock world marker.
    public static func hasWorldMarker(_ directory: URL) -> Bool {
        let fm = FileManager.default
        let markers = [
            "levelname.txt", "level.dat", "level.dat_old",
            "db", "world_db", "world_behavior_packs", "world_resource_packs",
        ]
        return markers.contains { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// True when anything under `root` (or `root` itself) is a symbolic link.
    private static func containsSymlink(_ root: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDir), !isDir.boolValue { return false }
        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )
        else { return false }
        for case let item as URL in enumerator {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                return true
            }
        }
        return false
    }

    /// Recursive byte size; unreadable entries count as zero rather than failing.
    private static func directorySize(_ root: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
