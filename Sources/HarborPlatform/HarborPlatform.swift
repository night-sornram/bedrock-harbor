import CryptoKit
import Foundation
import HarborDomain
import Security

// MARK: - Application Support paths

public struct HarborPaths: Sendable {
    public var applicationSupportRoot: URL
    public var cachesRoot: URL
    public var logsRoot: URL

    public init(
        applicationSupportRoot: URL,
        cachesRoot: URL,
        logsRoot: URL
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        self.cachesRoot = cachesRoot
        self.logsRoot = logsRoot
    }

    /// Canonical layout. Never concatenate usernames manually.
    public static func live(fileManager: FileManager = .default) throws -> HarborPaths {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let supportRoot = support.appendingPathComponent("BedrockHarbor", isDirectory: true)
        let cachesRoot = caches.appendingPathComponent("BedrockHarbor", isDirectory: true)
        let logsRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BedrockHarbor", isDirectory: true)
        return HarborPaths(
            applicationSupportRoot: supportRoot,
            cachesRoot: cachesRoot,
            logsRoot: logsRoot
        )
    }

    public var metadataDirectory: URL { applicationSupportRoot.appendingPathComponent("Metadata", isDirectory: true) }
    public var installationsDirectory: URL { applicationSupportRoot.appendingPathComponent("Installations", isDirectory: true) }
    public var runtimesDirectory: URL { applicationSupportRoot.appendingPathComponent("Runtimes", isDirectory: true) }
    public var patchesDirectory: URL { applicationSupportRoot.appendingPathComponent("Patches", isDirectory: true) }
    public var profilesDirectory: URL { applicationSupportRoot.appendingPathComponent("Profiles", isDirectory: true) }
    public var gameDataDirectory: URL { applicationSupportRoot.appendingPathComponent("GameData", isDirectory: true) }
    public var backupsDirectory: URL { applicationSupportRoot.appendingPathComponent("Backups", isDirectory: true) }
    public var compatibilityDirectory: URL { applicationSupportRoot.appendingPathComponent("Compatibility", isDirectory: true) }
    public var transactionsDirectory: URL { applicationSupportRoot.appendingPathComponent("Transactions", isDirectory: true) }

    public var downloadsCache: URL { cachesRoot.appendingPathComponent("Downloads", isDirectory: true) }
    public var stagingCache: URL { cachesRoot.appendingPathComponent("Staging", isDirectory: true) }
    public var gameCache: URL { cachesRoot.appendingPathComponent("Game", isDirectory: true) }

    public var launcherLogs: URL { logsRoot.appendingPathComponent("Launcher", isDirectory: true) }
    public var sessionLogs: URL { logsRoot.appendingPathComponent("Sessions", isDirectory: true) }

    public func profileDataURL(dataRootID: String) -> URL {
        gameDataDirectory
            .appendingPathComponent(dataRootID, isDirectory: true)
            .appendingPathComponent("games/com.mojang", isDirectory: true)
    }

    public func profileCacheURL(dataRootID: String) -> URL {
        gameCache.appendingPathComponent(dataRootID, isDirectory: true)
    }

    public func ensurePrivateDirectoryLayout() throws {
        let fm = FileManager.default
        let dirs = [
            metadataDirectory,
            installationsDirectory,
            runtimesDirectory,
            patchesDirectory,
            profilesDirectory,
            gameDataDirectory,
            backupsDirectory,
            compatibilityDirectory,
            transactionsDirectory,
            downloadsCache,
            stagingCache,
            gameCache,
            launcherLogs,
            sessionLogs,
        ]
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dir.path
            )
        }
    }
}

// MARK: - Redaction

public struct LogRedactor: Redacting, Sendable {
    public var extraPatterns: [String]
    public var homeDirectoryPath: String
    public var managedRootPaths: [String]

    public init(
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        managedRootPaths: [String] = [],
        extraPatterns: [String] = []
    ) {
        self.homeDirectoryPath = homeDirectoryPath
        self.managedRootPaths = managedRootPaths
        self.extraPatterns = extraPatterns
    }

    public func redact(_ text: String) -> String {
        var result = text
        // Managed roots first so home-path rewriting cannot hide them.
        for root in managedRootPaths where !root.isEmpty {
            result = result.replacingOccurrences(of: root, with: "<BH_ROOT>")
        }
        result = result.replacingOccurrences(of: homeDirectoryPath, with: "~")
        result = Self.applyPattern(
            #"(?i)bearer\s+[a-z0-9._\-]+"#,
            in: result,
            template: "Bearer <REDACTED>"
        )
        result = Self.applyPattern(
            #"(?i)(authorization|cookie|set-cookie|x-goog-authuser|device[_-]?token|aas[_-]?ticket|oauth[_-]?token|refresh[_-]?token|access[_-]?token)\s*[:=]\s*\S+"#,
            in: result,
            template: "$1: <REDACTED>"
        )
        result = Self.applyPattern(
            #"(?i)(sig|signature|token|key|password)=([^&\s]+)"#,
            in: result,
            template: "$1=<REDACTED>"
        )
        // Email-like account identifiers
        result = Self.applyPattern(
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            in: result,
            template: "<ACCOUNT>",
            options: [.caseInsensitive]
        )
        for pattern in extraPatterns {
            result = Self.applyPattern(pattern, in: result, template: "<REDACTED>")
        }
        return result
    }

    private static func applyPattern(
        _ pattern: String,
        in text: String,
        template: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

// MARK: - Keychain credential store

public struct KeychainCredentialStore: CredentialStore, Sendable {
    public var service: String

    public init(service: String = "com.bedrockharbor.credentials") {
        self.service = service
    }

    public func store(secret: Data, for reference: CredentialReference) async throws {
        try await runOnWorker {
            let query = baseQuery(for: reference)
            SecItemDelete(query as CFDictionary)
            var add = query
            add[kSecValueData as String] = secret
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw HarborError.credentialStoreUnavailable(reason: "Keychain add failed (\(status))")
            }
        }
    }

    public func retrieve(for reference: CredentialReference) async throws -> Data {
        try await runOnWorker {
            var query = baseQuery(for: reference)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess, let data = item as? Data else {
                if status == errSecItemNotFound {
                    throw HarborError.credentialStoreUnavailable(reason: "Secret not found")
                }
                throw HarborError.credentialStoreUnavailable(reason: "Keychain read failed (\(status))")
            }
            return data
        }
    }

    public func replace(secret: Data, for reference: CredentialReference) async throws {
        try await store(secret: secret, for: reference)
    }

    public func delete(for reference: CredentialReference) async throws {
        try await runOnWorker {
            let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw HarborError.credentialStoreUnavailable(reason: "Keychain delete failed (\(status))")
            }
        }
    }

    private func baseQuery(for reference: CredentialReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.opaqueDescription,
        ]
    }

    private func runOnWorker<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - In-memory credential store (tests / fakes)

public actor InMemoryCredentialStore: CredentialStore {
    private var storage: [String: Data] = [:]

    public init() {}

    public func store(secret: Data, for reference: CredentialReference) async throws {
        storage[reference.opaqueDescription] = secret
    }

    public func retrieve(for reference: CredentialReference) async throws -> Data {
        guard let data = storage[reference.opaqueDescription] else {
            throw HarborError.credentialStoreUnavailable(reason: "Secret not found")
        }
        return data
    }

    public func replace(secret: Data, for reference: CredentialReference) async throws {
        storage[reference.opaqueDescription] = secret
    }

    public func delete(for reference: CredentialReference) async throws {
        storage.removeValue(forKey: reference.opaqueDescription)
    }
}

// MARK: - Data-root lease

public actor DataRootLeaseCenter: DataRootLeasing {
    private var holders: [String: String] = [:]

    public init() {}

    public func acquire(dataRootID: String, owner: String) async throws {
        if let existing = holders[dataRootID], existing != owner {
            throw HarborError.gameRunning(profileID: UUID(uuidString: dataRootID) ?? UUID())
        }
        holders[dataRootID] = owner
    }

    public func release(dataRootID: String, owner: String) async {
        if holders[dataRootID] == owner {
            holders.removeValue(forKey: dataRootID)
        }
    }

    public func isHeld(dataRootID: String) async -> Bool {
        holders[dataRootID] != nil
    }
}

// MARK: - Atomic JSON metadata

public struct JSONMetadataStore: Sendable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func write<T: Encodable>(_ value: T, fileName: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        let destination = directory.appendingPathComponent(fileName)
        let temp = directory.appendingPathComponent(".\(fileName).tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public func read<T: Decodable>(_ type: T.Type, fileName: String) throws -> T? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

public struct FileMetadataRepository: MetadataRepository, Sendable {
    public var store: JSONMetadataStore

    public init(directory: URL) {
        self.store = JSONMetadataStore(directory: directory)
    }

    public func loadProfiles() async throws -> [Profile] {
        try store.read([Profile].self, fileName: "profiles.json") ?? []
    }

    public func saveProfiles(_ profiles: [Profile]) async throws {
        try store.write(profiles, fileName: "profiles.json")
    }

    public func loadInstallations() async throws -> [InstalledMinecraft] {
        try store.read([InstalledMinecraft].self, fileName: "installations.json") ?? []
    }

    public func saveInstallations(_ items: [InstalledMinecraft]) async throws {
        try store.write(items, fileName: "installations.json")
    }

    public func loadAccounts() async throws -> [AccountRecord] {
        try store.read([AccountRecord].self, fileName: "accounts.json") ?? []
    }

    public func saveAccounts(_ items: [AccountRecord]) async throws {
        try store.write(items, fileName: "accounts.json")
    }

    public func loadRuntimeInstallations() async throws -> [RuntimeInstallation] {
        try store.read([RuntimeInstallation].self, fileName: "runtimes.json") ?? []
    }

    public func saveRuntimeInstallations(_ items: [RuntimeInstallation]) async throws {
        try store.write(items, fileName: "runtimes.json")
    }
}

public actor InMemoryMetadataRepository: MetadataRepository {
    public var profiles: [Profile] = []
    public var installations: [InstalledMinecraft] = []
    public var accounts: [AccountRecord] = []
    public var runtimeInstallations: [RuntimeInstallation] = []

    public init() {}

    public func loadProfiles() async throws -> [Profile] { profiles }
    public func saveProfiles(_ profiles: [Profile]) async throws { self.profiles = profiles }
    public func loadInstallations() async throws -> [InstalledMinecraft] { installations }
    public func saveInstallations(_ items: [InstalledMinecraft]) async throws { self.installations = items }
    public func loadAccounts() async throws -> [AccountRecord] { accounts }
    public func saveAccounts(_ items: [AccountRecord]) async throws { self.accounts = items }
    public func loadRuntimeInstallations() async throws -> [RuntimeInstallation] { runtimeInstallations }
    public func saveRuntimeInstallations(_ items: [RuntimeInstallation]) async throws { self.runtimeInstallations = items }
}

// MARK: - Archive path safety (hardened policy core)

public enum ArchivePathPolicy: Sendable {
    public struct Decision: Sendable, Equatable {
        public var isAccepted: Bool
        public var reason: String?

        public init(isAccepted: Bool, reason: String? = nil) {
            self.isAccepted = isAccepted
            self.reason = reason
        }

        public static let accepted = Decision(isAccepted: true)
        public static func rejected(_ reason: String) -> Decision {
            Decision(isAccepted: false, reason: reason)
        }
    }

    /// Validate a single archive entry path for game/content extraction.
    public static func evaluateEntryPath(
        _ rawPath: String,
        allowSymlink: Bool = false,
        isSymlink: Bool = false,
        maxPathDepth: Int = 32,
        maxPathLength: Int = 1024
    ) -> Decision {
        if rawPath.isEmpty {
            return .rejected("Empty path")
        }
        if rawPath.contains("\0") {
            return .rejected("NUL in path")
        }
        if rawPath.count > maxPathLength {
            return .rejected("Path too long")
        }
        if rawPath.hasPrefix("/") || rawPath.hasPrefix("~") {
            return .rejected("Absolute or home-relative path")
        }
        // Windows drive / UNC
        if rawPath.count >= 2, rawPath.rawIndex(1) == ":" {
            return .rejected("Drive-qualified path")
        }
        if rawPath.hasPrefix("\\\\") {
            return .rejected("UNC path")
        }

        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map(String.init)
        if components.isEmpty {
            return .rejected("No path components")
        }
        if components.count > maxPathDepth {
            return .rejected("Path depth exceeded")
        }
        for component in components {
            if component == ".." {
                return .rejected("Parent traversal")
            }
            if component == "." {
                return .rejected("Dot component")
            }
            if component.contains(":") {
                return .rejected("Colon in component")
            }
            if component != component.precomposedStringWithCanonicalMapping {
                return .rejected("Non-canonical Unicode path component")
            }
        }

        if isSymlink && !allowSymlink {
            return .rejected("Symlinks are not permitted in game/content archives")
        }

        return .accepted
    }

    /// Detect case-insensitive / unicode collisions among accepted relative paths.
    public static func detectCollisions(paths: [String]) -> [String] {
        var seen = [String: String]()
        var collisions: [String] = []
        for path in paths {
            let key = path.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if let previous = seen[key], previous != path {
                collisions.append(path)
            } else {
                seen[key] = path
            }
        }
        return collisions
    }
}

private extension String {
    func rawIndex(_ offset: Int) -> Character? {
        guard offset >= 0, offset < count else { return nil }
        return self[index(startIndex, offsetBy: offset)]
    }
}

// MARK: - SHA-256 helper

public enum Hashing: Sendable {
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Disk space

public enum DiskSpace: Sendable {
    public static func availableBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        if let free = attrs[.systemFreeSize] as? Int64 {
            return free
        }
        throw HarborError.internalInconsistency(reason: "Unable to determine free disk space")
    }
}
