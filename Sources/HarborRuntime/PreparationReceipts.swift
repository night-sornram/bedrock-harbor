import Foundation

/// Proof that game-package preparation already ran for one exact launch configuration.
/// When a stored receipt's inputs and post-preparation fingerprints all match, the
/// heavy filesystem work (library restore/swaps, storage patch, guest libc repair)
/// can be skipped entirely for that launch.
///
/// Fingerprints are POST-preparation state: `StorageQueryCompatibilityPatch` edits
/// libminecraftpe.so in place, so fingerprinting the pre-state would invalidate the
/// receipt on every launch. Any drift between the recorded post-state and the
/// current lib directory (re-import, corruption, an outside patcher) falls through
/// to the slow path, which is idempotent and re-repairs.
public struct PreparationReceipt: Codable, Sendable, Equatable {
    public var gameVersionName: String
    public var gameDirectoryPath: String
    public var runtimeRootPath: String
    /// Mod metadata version, or "none" when no metadata exists.
    public var patchVersion: String
    public var bypassedOfficialMod: Bool
    /// lib name -> "size:mtime" AFTER preparation.
    public var gameLibFingerprints: [String: String]
    public var storagePatchApplied: Bool
    public var createdAt: Date

    public init(
        gameVersionName: String,
        gameDirectoryPath: String,
        runtimeRootPath: String,
        patchVersion: String,
        bypassedOfficialMod: Bool,
        gameLibFingerprints: [String: String],
        storagePatchApplied: Bool,
        createdAt: Date
    ) {
        self.gameVersionName = gameVersionName
        self.gameDirectoryPath = gameDirectoryPath
        self.runtimeRootPath = runtimeRootPath
        self.patchVersion = patchVersion
        self.bypassedOfficialMod = bypassedOfficialMod
        self.gameLibFingerprints = gameLibFingerprints
        self.storagePatchApplied = storagePatchApplied
        self.createdAt = createdAt
    }
}

/// Persistence for preparation receipts: "<harborSupport>/Compatibility/
/// preparation-receipts.json". Purely a disposable cache — a missing or corrupt
/// file only costs one slow preparation pass, never correctness.
public enum PreparationReceiptStore: Sendable {
    /// Bounded history: enough for every game version/dir pairing a user actively
    /// launches, without growing forever.
    static let maxReceipts = 20

    static func receiptsFileURL(root: URL) -> URL {
        root.appendingPathComponent("Compatibility/preparation-receipts.json", isDirectory: false)
    }

    public static func load(root: URL) -> [PreparationReceipt] {
        guard let data = try? Data(contentsOf: receiptsFileURL(root: root)) else { return [] }
        return (try? JSONDecoder().decode([PreparationReceipt].self, from: data)) ?? []
    }

    /// Keeps the newest `maxReceipts` receipts by creation date.
    public static func save(_ receipts: [PreparationReceipt], root: URL) {
        let newest = Array(receipts.sorted { $0.createdAt > $1.createdAt }.prefix(maxReceipts))
        guard let data = try? JSONEncoder().encode(newest) else { return }
        let url = receiptsFileURL(root: root)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// "size:mtime" for every file in the game package's lib/arm64-v8a directory.
    /// Covers regular libraries plus backups and patch markers, so any filesystem
    /// change to the directory is visible to receipt matching.
    public static func fingerprints(gameDirectory: URL) -> [String: String] {
        let libDir = gameDirectory.appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: libDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else { return [:] }
        var prints: [String: String] = [:]
        for entry in entries {
            guard let values = try? entry.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            prints[entry.lastPathComponent] = "\(size):\(mtime)"
        }
        return prints
    }
}

/// Detailed result of launch preparation: the mod directory decision plus whether
/// the work was skipped via receipt and what was actually changed.
public struct PreparationOutcome: Sendable {
    /// Official mod directory to pass via `-m`; nil → official mod bypassed.
    public var modDirectory: URL?
    public var reusedReceipt: Bool
    /// Human-readable description of each applied filesystem change (empty when
    /// the receipt fast path skipped preparation).
    public var appliedChanges: [String]

    public init(modDirectory: URL?, reusedReceipt: Bool, appliedChanges: [String]) {
        self.modDirectory = modDirectory
        self.reusedReceipt = reusedReceipt
        self.appliedChanges = appliedChanges
    }
}
