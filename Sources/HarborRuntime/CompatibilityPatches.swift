import Foundation
import HarborDomain
import HarborPlatform

/// Official minecraft-linux `mcpelauncher-updates` compatibility mod (public moddb).
///
/// Usage mirrors the official launcher: the mod directory is passed to mcpelauncher via `-m`.
/// The launcher's ModLoader dlopens only top-level `.so` files (its directory scan is not
/// recursive), loading `libmcpelauncher-updates.so`, which patches symbol/vtable resolution at
/// runtime so newer Bedrock builds load on the macOS runtime.
///
/// The `patches/**` tree inside the mod zip is version-pinned data (e.g.
/// `patches/v1.26.0.2/arm64-v8a/libmaesdk.so` applies to game 1.26.0.2 only). No part of the
/// official launcher copies those files into the game directory, and doing so corrupts the
/// package (a mismatched libmaesdk crashes startup in the auth/HttpClient path). Harbor never
/// copies those version-pinned files; before launch it restores any previously swapped
/// library from its `.so.bck` backup so the package stays pristine. The one in-place game
/// binary edit Harbor makes is `StorageQueryCompatibilityPatch` (four bytes, `.so.orig`
/// backup) — see its documentation for why the game itself must be patched.
public struct HarborCompatibilityPatches: Sendable {
    public static let modDBURL = URL(string: "https://raw.githubusercontent.com/minecraft-linux/mcpelauncher-moddb/main/moddb.json")!
    public static let abi = "arm64-v8a"
    public static let modName = "mcpelauncher-updates"
    public static let modLibraryName = "libmcpelauncher-updates.so"

    public struct Metadata: Codable, Sendable {
        public var version: String
        public var assetURL: String
        public var installPath: String
        public var supportedVersionCodes: [Int]
        public var supportedVersionNames: [String]
        /// When the moddb catalog was last consulted. Optional so metadata.json files
        /// written before daily refresh existed keep decoding (they decode as nil,
        /// which counts as stale and triggers one background refresh).
        public var catalogCheckedAt: Date? = nil
    }

    private struct ModDBEntry: Decodable {
        var name: String
        var versions: [ModDBVersion]
    }

    private struct ModDBVersion: Decodable {
        var version: String
        var assets: [String: String]?
        var extraVersions: [ModDBExtraVersion]?
        var provides: [String: ModDBProvides]?

        enum CodingKeys: String, CodingKey {
            case version, assets, provides
            case extraVersions = "extraVersions"
        }
    }

    private struct ModDBProvides: Decodable {
        var extraVersions: [ModDBExtraVersion]?
    }

    private struct ModDBExtraVersion: Decodable {
        var versionName: String
        var codes: [String: Int]

        enum CodingKeys: String, CodingKey {
            case codes
            case versionName = "version_name"
        }
    }

    /// Test seam: overrides the compat-patch storage root (nil in production).
    nonisolated(unsafe) static var harborRootOverride: URL?

    public static var harborRoot: URL {
        harborRootOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BedrockHarbor/CompatibilityPatches", isDirectory: true)
    }

    /// Test seam: replaces the moddb network fetch (nil in production).
    nonisolated(unsafe) static var catalogLoader: (@Sendable () async throws -> Data)?

    /// Test seam: clock injection for the daily refresh gate.
    nonisolated(unsafe) static var now: @Sendable () -> Date = { Date() }

    /// Bounded-timeout session for all compat-patch network I/O: a stalled moddb fetch or
    /// asset download fails in seconds instead of hanging the launch path for the
    /// URLSession.shared defaults (multi-minute request timeout).
    private static let timedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    private static var metadataURL: URL {
        harborRoot.appendingPathComponent("metadata.json", isDirectory: false)
    }

    public static func loadMetadata() -> Metadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    public static func installedModDirectory() -> URL? {
        guard let meta = loadMetadata() else { return nil }
        let dir = URL(fileURLWithPath: meta.installPath, isDirectory: true)
        let mod = dir.appendingPathComponent(modLibraryName, isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: mod.path) ? dir : nil
    }

    // MARK: - Version support

    public static func supports(versionCode: Int64? = nil, versionName: String? = nil) -> Bool {
        guard let meta = loadMetadata() else { return false }
        return metadataSupports(meta, versionCode: versionCode, versionName: versionName)
    }

    static func metadataSupports(_ meta: Metadata, versionCode: Int64?, versionName: String?) -> Bool {
        if let code = versionCode, meta.supportedVersionCodes.contains(Int(code)) { return true }
        if let versionName,
           meta.supportedVersionNames.contains(where: { versionNameMatches(versionName, supported: $0) }) {
            return true
        }
        return false
    }

    /// Exact match, or equal first three numeric components ("1.26.51" covers "1.26.51.1").
    static func versionNameMatches(_ game: String, supported: String) -> Bool {
        let g = versionComponents(game)
        let s = versionComponents(supported)
        if g.isEmpty || s.isEmpty { return false }
        if g == s { return true }
        guard g.count >= 3, s.count >= 3 else { return false }
        return Array(g.prefix(3)) == Array(s.prefix(3))
    }

    /// Numeric components of a dotted version name; a single leading "v" is tolerated.
    static func versionComponents(_ name: String) -> [Int] {
        name.split(separator: ".").compactMap { component -> Int? in
            var comp = Substring(component)
            if comp.first == "v" || comp.first == "V" { comp = comp.dropFirst() }
            return Int(comp)
        }
    }

    static func compareVersions(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    static func maxSupportedVersionName(in names: [String]) -> String? {
        names.max { compareVersions(versionComponents($0), versionComponents($1)) < 0 }
    }

    // MARK: - Known-broken official mod ranges

    public struct KnownIncompatibility: Sendable {
        public let gameVersionMin: String
        public let gameVersionMax: String
        public let modVersionMaxInclusive: String
        public let reason: String
    }

    /// Empirically verified 2026-09-18 on macOS arm64 (macos-builder v1.8.4-573 +
    /// mcpelauncher-updates asset v26.40.1, newest upstream at the time): Bedrock
    /// 1.26.50–1.26.51 crash during startup inside the official mod's pairip/HttpClient hook
    /// (recursive shim::pthread_mutex_lock → SIGSEGV), even though moddb claims support.
    /// For these versions Harbor bypasses the official mod entirely and applies its own
    /// compatibility stack: guest libc hash repair (GuestLibcCompatibilityPatch), the
    /// freestanding symbol shim mod (ldiv & fortify family), and the patch bundle's universal
    /// game libraries (rebuilt libPlayFabMultiplayer.so — the bundled one crashes in its
    /// static constructors on the macOS shim). Verified: Minecraft 1.26.51.1 loads and runs
    /// stably with that stack. Entries apply only while the resolved mod release is at or
    /// below `modVersionMaxInclusive`, so Harbor returns to the official mod automatically
    /// once a fixed release ships.
    public static let knownIncompatibilities: [KnownIncompatibility] = [
        KnownIncompatibility(
            gameVersionMin: "1.26.50",
            gameVersionMax: "1.26.51",
            modVersionMaxInclusive: "1.26.45.1",
            reason: "official mcpelauncher-updates mod crashes during startup (verified with Minecraft 1.26.51.1)"
        ),
    ]

    /// Mod release versions: current scheme names the game ("1.26.45.1"); the legacy scheme
    /// dropped the leading "1." ("26.40.1"). Normalizes legacy tags to game-style components.
    static func modVersionComponents(_ version: String) -> [Int] {
        var components = versionComponents(version)
        if components.first ?? 0 >= 20, components.count == 3 {
            components = [1] + components
        }
        return components
    }

    /// First-three-component comparison: "1.26.51.1" belongs to the "1.26.51" generation.
    static func knownIncompatibility(gameVersionName: String, modVersion: String) -> KnownIncompatibility? {
        let gameFull = versionComponents(gameVersionName)
        guard gameFull.count >= 3 else { return nil }
        let game = Array(gameFull.prefix(3))
        let mod = modVersionComponents(modVersion)
        func generation(_ name: String) -> [Int]? {
            let c = versionComponents(name)
            return c.count >= 3 ? Array(c.prefix(3)) : nil
        }
        for rule in knownIncompatibilities {
            guard !mod.isEmpty,
                  compareVersions(mod, modVersionComponents(rule.modVersionMaxInclusive)) <= 0,
                  let lo = generation(rule.gameVersionMin),
                  let hi = generation(rule.gameVersionMax)
            else { continue }
            if compareVersions(game, lo) >= 0 && compareVersions(game, hi) <= 0 {
                return rule
            }
        }
        return nil
    }

    // MARK: - Harbor compat stack (official mod bypassed)

    /// Universal replacement libraries from the official patch bundle: root-level `patches/*.so`
    /// apply to any game version (version-pinned `patches/v*/` folders are the official mod's
    /// business and are never touched here). The rebuilt libPlayFabMultiplayer.so is required
    /// for 1.26.5x — the game's bundled one crashes in its static constructors on the macOS
    /// shim. Backs up the original next to the destination, mirroring the official mod.
    @discardableResult
    public static func applyUniversalGameLibraries(modDirectory: URL, gameDirectory: URL) -> [String] {
        let fm = FileManager.default
        let patchRoot = modDirectory.appendingPathComponent("patches", isDirectory: true)
        let destLib = gameDirectory.appendingPathComponent("lib/\(abi)", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: patchRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var applied: [String] = []
        for src in entries where src.pathExtension == "so" {
            let dest = destLib.appendingPathComponent(src.lastPathComponent)
            guard fm.fileExists(atPath: dest.path) else { continue }
            do {
                if let srcData = try? Data(contentsOf: src),
                   let destData = try? Data(contentsOf: dest),
                   srcData == destData {
                    continue
                }
                let bak = dest.deletingPathExtension().appendingPathExtension("so.bck")
                if !fm.fileExists(atPath: bak.path) {
                    try fm.copyItem(at: dest, to: bak)
                }
                try fm.removeItem(at: dest)
                try fm.copyItem(at: src, to: dest)
                applied.append(src.lastPathComponent)
            } catch {
                // Best-effort; a missing replacement fails at game load with a clear error.
            }
        }
        return applied
    }

    /// Version-pinned rebuilds from the official patch bundle (`patches/v*/arm64-v8a/`):
    /// upstream ships macOS-compatible rebuilds of game libraries whose shipped builds
    /// crash on the mcpelauncher runtime — Minecraft 1.26.5x's own libmaesdk.so dies in
    /// its static constructor (verified 2026-09-18: the game only runs with the
    /// v1.26.0.2 rebuild; SIGSEGV jumps into mangled-name strings otherwise).
    /// Applied only on the official-mod bypass path, with .bck backup like the universal
    /// swap; only replaces libraries the game already ships.
    @discardableResult
    public static func applyVersionPinnedRebuilds(modDirectory: URL, gameDirectory: URL) -> [String] {
        let fm = FileManager.default
        let patchRoot = modDirectory.appendingPathComponent("patches", isDirectory: true)
        let destLib = gameDirectory.appendingPathComponent("lib/\(abi)", isDirectory: true)
        guard let versions = try? fm.contentsOfDirectory(at: patchRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var applied: [String] = []
        for vdir in versions where vdir.lastPathComponent.hasPrefix("v") {
            let libDir = vdir.appendingPathComponent(abi, isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(at: libDir, includingPropertiesForKeys: nil) else { continue }
            for src in entries where src.pathExtension == "so" {
                let dest = destLib.appendingPathComponent(src.lastPathComponent)
                guard fm.fileExists(atPath: dest.path) else { continue }
                if let srcData = try? Data(contentsOf: src),
                   let destData = try? Data(contentsOf: dest),
                   srcData == destData {
                    continue
                }
                do {
                    let bak = dest.deletingPathExtension().appendingPathExtension("so.bck")
                    if !fm.fileExists(atPath: bak.path) {
                        try fm.copyItem(at: dest, to: bak)
                    }
                    try fm.removeItem(at: dest)
                    try fm.copyItem(at: src, to: dest)
                    applied.append("\(vdir.lastPathComponent)/\(src.lastPathComponent)")
                } catch {
                    // Best-effort; a missing replacement fails at game load with a clear error.
                }
            }
        }
        return applied
    }

    /// Installs the bundled freestanding symbol shim (ldiv, lldiv, div, fortify family) as a
    /// guest mod under Patches/<gameVersion>/arm64-v8a, which Harbor passes via `-m`.
    /// The shim injects its implementations into the guest libc.so at mod_preinit using
    /// mcpelauncher_relocate — the same mechanism the official mcpelauncher-updates mod uses.
    @discardableResult
    public static func ensureSymbolShimInstalled(gameVersionName: String) throws -> URL? {
        let fm = FileManager.default
        let destDir = LocalRuntimeDiscovery.harborSupport
            .appendingPathComponent("Patches/\(gameVersionName)/arm64-v8a", isDirectory: true)
        let dest = destDir.appendingPathComponent("libharbor_symbol_shim.so", isDirectory: false)
        if let size = try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int, size > 0 {
            return dest
        }
        guard let bundled = Bundle.module.url(forResource: "libharbor_symbol_shim", withExtension: "so") else {
            return nil
        }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: bundled, to: dest)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }

    // MARK: - Resolution

    /// Resolve the arm64 asset with the broadest game coverage from the public moddb.
    public static func resolveLatest() async throws -> (version: String, assetURL: URL, codes: [Int], names: [String]) {
        let data: Data
        if let catalogLoader {
            data = try await catalogLoader()
        } else {
            let (fetched, response) = try await timedSession.data(from: modDBURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw HarborError.providerFailure(reason: "moddb HTTP \(http.statusCode)")
            }
            data = fetched
        }
        let entries = try JSONDecoder().decode([ModDBEntry].self, from: data)
        guard let entry = entries.first(where: { $0.name == modName }) else {
            throw HarborError.providerFailure(reason: "\(modName) missing from moddb")
        }
        struct Ranked {
            var version: String
            var url: URL
            var maxCode: Int
            var codes: [Int]
            var names: [String]
        }
        var ranked: [Ranked] = []
        for ver in entry.versions {
            guard let raw = ver.assets?[abi], let url = URL(string: raw) else { continue }
            var codes: [Int] = []
            var names: [String] = []
            func collect(_ extras: [ModDBExtraVersion]?) {
                for extra in extras ?? [] {
                    if let code = extra.codes[abi] {
                        codes.append(code)
                        names.append(extra.versionName)
                    }
                }
            }
            collect(ver.extraVersions)
            if let provides = ver.provides {
                for provide in provides.values {
                    collect(provide.extraVersions)
                }
            }
            ranked.append(Ranked(version: ver.version, url: url, maxCode: codes.max() ?? 0, codes: codes, names: names))
        }
        // Prefer the highest covered game version code; break ties by broader coverage, then by
        // later position in moddb order (the list is chronological, so later is newer).
        guard let bestIndex = ranked.indices.max(by: { a, b in
            let l = ranked[a], r = ranked[b]
            if l.maxCode != r.maxCode { return l.maxCode < r.maxCode }
            let lCoverage = l.codes.count + l.names.count
            let rCoverage = r.codes.count + r.names.count
            if lCoverage != rCoverage { return lCoverage < rCoverage }
            return a < b
        }) else {
            throw HarborError.providerFailure(reason: "No arm64 \(modName) asset in moddb")
        }
        let best = ranked[bestIndex]
        return (best.version, best.url, best.codes, best.names)
    }

    // MARK: - Install

    /// Reuse the installed patch when it is the same moddb release, or when the asset is
    /// byte-identical (same URL) and it already covers the game version in hand. A nil
    /// `coversGame` means no game version context; identical bytes are then always fine.
    static func shouldReuseInstalled(
        installedVersion: String?,
        installedAssetURL: String?,
        coversGame: Bool?,
        latestVersion: String,
        latestAssetURL: String
    ) -> Bool {
        guard let installedVersion, !installedVersion.isEmpty else { return false }
        if installedVersion == latestVersion { return true }
        guard installedAssetURL == latestAssetURL else { return false }
        return coversGame ?? true
    }

    /// Download/extract the mod if needed and return its directory for `-m`.
    /// Repeat launches are network-free: when the installed patch is intact and covers the
    /// game version, it is returned immediately and the moddb catalog is refreshed at most
    /// once a day in the background. A missing install, or a game version the installed
    /// metadata does not cover, still resolves moddb synchronously so a newer release can
    /// upgrade the install (or positively block the launch) before the game starts.
    @discardableResult
    public static func ensureInstalled(gameVersionName: String? = nil) async throws -> URL {
        if let meta = loadMetadata(),
           let installed = installedModDirectory(),
           gameVersionName.map({ metadataSupports(meta, versionCode: nil, versionName: $0) }) ?? true {
            if catalogNeedsRefresh(checkedAt: meta.catalogCheckedAt) {
                refreshCatalogInBackground()
            }
            return installed
        }
        return try await resolveAndInstall(gameVersionName: gameVersionName)
    }

    /// Force a catalog refresh now: resolve moddb and install when the release differs
    /// (wired to a Settings action). Unlike the background refresh, throws on failure.
    @discardableResult
    public static func refreshCatalogNow() async throws -> URL {
        try await resolveAndInstall(gameVersionName: nil)
    }

    /// Minimum time between moddb consultations.
    static let catalogRefreshInterval: TimeInterval = 24 * 60 * 60

    /// The catalog must be consulted again when it never was, or more than a day ago.
    static func catalogNeedsRefresh(checkedAt: Date?) -> Bool {
        guard let checkedAt else { return true }
        return now().timeIntervalSince(checkedAt) >= catalogRefreshInterval
    }

    /// Single-flight gate: at most one background catalog refresh runs per process.
    private actor CatalogRefreshGate {
        private var inFlight = false

        /// Returns false when a refresh is already running.
        func claim() -> Bool {
            guard !inFlight else { return false }
            inFlight = true
            return true
        }

        func release() {
            inFlight = false
        }
    }

    private static let refreshGate = CatalogRefreshGate()

    /// Fire-and-forget catalog refresh: resolves moddb and, when the release differs,
    /// downloads + installs the update. At most one refresh runs per process; failures are
    /// silent because the existing install keeps working.
    static func refreshCatalogInBackground() {
        Task.detached(priority: .utility) {
            guard await refreshGate.claim() else { return }
            _ = try? await resolveAndInstall(gameVersionName: nil)
            await refreshGate.release()
        }
    }

    /// Slow path shared by first install, uncovered game versions, and explicit refresh:
    /// resolve moddb, reuse the existing install when possible, download + install when the
    /// release differs, and stamp `catalogCheckedAt` so the daily refresh gate closes.
    @discardableResult
    private static func resolveAndInstall(gameVersionName: String?) async throws -> URL {
        let installedMeta = loadMetadata()
        let latest: (version: String, assetURL: URL, codes: [Int], names: [String])
        do {
            latest = try await resolveLatest()
        } catch {
            // Offline: keep the current install; unsupported game versions are blocked at
            // launch only when coverage data positively rules them out.
            if let existing = installedModDirectory() { return existing }
            throw error
        }

        if let existing = installedModDirectory(), let meta = installedMeta {
            let coversGame = gameVersionName.map {
                metadataSupports(meta, versionCode: nil, versionName: $0)
            }
            if shouldReuseInstalled(
                installedVersion: meta.version,
                installedAssetURL: meta.assetURL,
                coversGame: coversGame,
                latestVersion: latest.version,
                latestAssetURL: latest.assetURL.absoluteString
            ) {
                stampCatalogCheckedAt(meta)
                return existing
            }
        }

        let installPath = harborRoot
            .appendingPathComponent(latest.version, isDirectory: true)
            .appendingPathComponent(abi, isDirectory: true)
        try FileManager.default.createDirectory(at: harborRoot, withIntermediateDirectories: true)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborCompat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (downloaded, response) = try await timedSession.download(from: latest.assetURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HarborError.providerFailure(reason: "compat patch HTTP \(http.statusCode)")
        }
        let zipURL = tmp.appendingPathComponent(latest.assetURL.lastPathComponent)
        try FileManager.default.moveItem(at: downloaded, to: zipURL)
        let extractURL = tmp.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractURL, withIntermediateDirectories: true)
        let ditto = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", zipURL.path, extractURL.path]
        )
        guard ditto.exitCode == 0, !ditto.timedOut else {
            throw HarborError.providerFailure(reason: "ditto extract failed (\(ditto.exitCode))")
        }

        if FileManager.default.fileExists(atPath: installPath.path) {
            try FileManager.default.removeItem(at: installPath)
        }
        try FileManager.default.createDirectory(at: installPath, withIntermediateDirectories: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: extractURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for item in contents {
            let dest = installPath.appendingPathComponent(item.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: item, to: dest)
        }
        let modLib = installPath.appendingPathComponent(modLibraryName)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: modLib.path)
        guard FileManager.default.isExecutableFile(atPath: modLib.path) else {
            throw HarborError.providerFailure(reason: "compat patch missing \(modLibraryName)")
        }
        let meta = Metadata(
            version: latest.version,
            assetURL: latest.assetURL.absoluteString,
            installPath: installPath.path,
            supportedVersionCodes: latest.codes,
            supportedVersionNames: latest.names,
            catalogCheckedAt: now()
        )
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metadataURL, options: .atomic)
        }
        return installPath
    }

    /// Record that the moddb catalog was just consulted (closes the daily refresh gate).
    private static func stampCatalogCheckedAt(_ meta: Metadata) {
        var stamped = meta
        stamped.catalogCheckedAt = now()
        if let data = try? JSONEncoder().encode(stamped) {
            try? data.write(to: metadataURL, options: .atomic)
        }
    }

    // MARK: - Game package repair

    /// Undo earlier in-place game library patching: for every `*.so.bck` backup sitting next to
    /// a game library, restore the pristine `.so` from it. The backups are kept, so this is
    /// idempotent. Returns the restored library file names.
    @discardableResult
    public static func restorePatchedGameLibraries(gameDirectory: URL) -> [String] {
        let fm = FileManager.default
        let libDir = gameDirectory.appendingPathComponent("lib/\(abi)", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: libDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var restored: [String] = []
        for backup in entries where backup.pathExtension == "bck" {
            let original = backup.deletingPathExtension()
            guard original.pathExtension == "so" else { continue }
            do {
                if fm.fileExists(atPath: original.path) {
                    try fm.removeItem(at: original)
                }
                try fm.copyItem(at: backup, to: original)
                restored.append(original.lastPathComponent)
            } catch {
                // Best-effort repair; the mod still patches compatibility at runtime.
            }
        }
        return restored
    }

    // MARK: - Launch preparation

    /// Prepare compatibility for launch. Returns the official mod directory to pass via `-m`,
    /// or nil when the official mod is known-broken for this game version — in that case
    /// Harbor applies its own compat stack (guest libc hash repair, symbol shim mod,
    /// universal game libraries) and the game must run without the official mod.
    /// Throws `.compatibilityBlocked` when no known-good path exists for the game version.
    public static func prepareForLaunch(
        gameDirectory: URL,
        versionName: String? = nil,
        versionCode: Int64? = nil,
        runtimeRoot: URL? = nil
    ) async throws -> URL? {
        let modDir = try await ensureInstalled(gameVersionName: versionName)
        guard let versionName, let meta = loadMetadata() else {
            restorePatchedGameLibraries(gameDirectory: gameDirectory)
            _ = StorageQueryCompatibilityPatch.patch(gameDirectory: gameDirectory)
            return modDir
        }

        if knownIncompatibility(gameVersionName: versionName, modVersion: meta.version) != nil {
            // Official mod crashes for this game generation (see the rule's reason): bypass it and
            // apply Harbor's stack. Verified with Minecraft 1.26.51.1 on runtime v1.8.4-573.
            if let runtimeRoot {
                _ = GuestLibcCompatibilityPatch.patch(runtimeRoot: runtimeRoot)
            }
            _ = try? ensureSymbolShimInstalled(gameVersionName: versionName)
            restorePatchedGameLibraries(gameDirectory: gameDirectory)
            applyUniversalGameLibraries(modDirectory: modDir, gameDirectory: gameDirectory)
            applyVersionPinnedRebuilds(modDirectory: modDir, gameDirectory: gameDirectory)
            _ = StorageQueryCompatibilityPatch.patch(gameDirectory: gameDirectory)
            return nil
        }

        if !meta.supportedVersionNames.isEmpty,
           !metadataSupports(meta, versionCode: versionCode, versionName: versionName) {
            let maxKnown = maxSupportedVersionName(in: meta.supportedVersionNames) ?? "?"
            throw HarborError.compatibilityBlocked(
                reason: """
                Minecraft \(versionName) is newer than the mcpelauncher-updates patch on this Mac \
                (covers up to \(maxKnown)), so the launcher runtime would crash during startup. \
                Import an owned package of a supported version, or reconnect to the internet and \
                retry so Harbor can fetch a newer patch.
                """
            )
        }
        restorePatchedGameLibraries(gameDirectory: gameDirectory)
        _ = StorageQueryCompatibilityPatch.patch(gameDirectory: gameDirectory)
        return modDir
    }
}
