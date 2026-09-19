import Foundation
import HarborDomain
import HarborPlatform

public struct ApprovalCatalog: Sendable {
    public var releases: [RuntimeRelease]
    public init(releases: [RuntimeRelease] = []) { self.releases = releases }
    public static let foundation = ApprovalCatalog(releases: [])
    public func release(id: String) -> RuntimeRelease? { releases.first { $0.id == id } }
}

public struct RuntimeArtifactVerifier: Sendable {
    public init() {}
    public func verifySHA256(fileURL: URL, expected: String) throws {
        let actual = try Hashing.sha256Hex(ofFile: fileURL)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw HarborError.integrityFailure(reason: "Runtime artifact hash mismatch")
        }
    }
    public func inspectArchitecture(executableURL: URL) throws -> RuntimeRelease.Architecture {
        let handle = try FileHandle(forReadingFrom: executableURL)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 8)
        guard data.count >= 8 else {
            throw HarborError.invalidPackage(reason: "Executable too small to be Mach-O")
        }
        let thin64LE: UInt32 = 0xfeedfacf
        let thin64BE: UInt32 = 0xcffaedfe
        let fatBE: UInt32 = 0xcafebabe
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        if magic == fatBE || magic == 0xbebafeca { return .universal }
        if magic == thin64LE || magic == thin64BE {
            let cpuType = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
            let swapped = cpuType.bigEndian
            if cpuType == 0x0100_000c || swapped == 0x0100_000c || cpuType == 0x0c00_0001 || swapped == 0x0c00_0001 {
                return .arm64
            }
            if cpuType == 0x0100_0007 || swapped == 0x0100_0007 { return .x86_64 }
            throw HarborError.invalidPackage(reason: "Unsupported Mach-O CPU type")
        }
        throw HarborError.invalidPackage(reason: "Not a recognized Mach-O executable")
    }
}

/// Launch layout for mcpelauncher-client (CLI from the binary's --help, not third-party UI code).
public struct MCLauncherClientLayout: Sendable, Hashable {
    public var runtimeRootURL: URL
    public var executableURL: URL
    public var gameDirectoryURL: URL
    public var releaseID: String
    public var versionLabel: String
    public var modsDirectories: [String]
    public var xdgDataDirs: [String]
    public var forceOpenGLES: Bool

    public init(
        runtimeRootURL: URL,
        executableURL: URL,
        gameDirectoryURL: URL,
        releaseID: String,
        versionLabel: String,
        modsDirectories: [String] = [],
        xdgDataDirs: [String] = [],
        forceOpenGLES: Bool = true
    ) {
        self.runtimeRootURL = runtimeRootURL
        self.executableURL = executableURL
        self.gameDirectoryURL = gameDirectoryURL
        self.releaseID = releaseID
        self.versionLabel = versionLabel
        self.modsDirectories = modsDirectories
        self.xdgDataDirs = xdgDataDirs
        self.forceOpenGLES = forceOpenGLES
    }

    /// hugonote-compatible working directory: runtime root when client lives in MacOS/.
    public var preferredWorkingDirectory: URL {
        let macos = executableURL.deletingLastPathComponent()
        if macos.lastPathComponent == "MacOS" {
            return macos.deletingLastPathComponent()
        }
        return macos
    }

    public func arguments(
        dataDirectory: URL,
        cacheDirectory: URL,
        extraMods: [String] = [],
        compatibilityPatchPath: URL? = nil
    ) -> [String] {
        var args = ["--disable-fmod"]
        if forceOpenGLES { args += ["-fes"] }
        var mods = modsDirectories + extraMods
        if let compatibilityPatchPath {
            mods.append(compatibilityPatchPath.path)
        }
        if !mods.isEmpty { args += ["-m", mods.joined(separator: ",")] }
        args += ["-dd", dataDirectory.path, "-dc", cacheDirectory.path, "-dg", gameDirectoryURL.path]
        return args
    }

    public func launchEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "MCPELAUNCHER_GOOGLE_EMAIL")
        env.removeValue(forKey: "MCPELAUNCHER_GOOGLE_TOKEN")
        env.removeValue(forKey: "MCPELAUNCHER_GOOGLE_CREDENTIAL_FILE")
        env["SDL_AUDIODRIVER"] = ProcessInfo.processInfo.environment["SDL_AUDIODRIVER"] ?? "coreaudio"
        env["AUDIO_SAMPLE_RATE"] = ProcessInfo.processInfo.environment["AUDIO_SAMPLE_RATE"] ?? "48000"
        var xdg = xdgDataDirs
        if let existing = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"], !existing.isEmpty {
            xdg.append(existing)
        }
        if !xdg.isEmpty { env["XDG_DATA_DIRS"] = xdg.joined(separator: ":") }
        let macosDir = executableURL.deletingLastPathComponent().path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = macosDir + ":" + path
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        for (k, v) in extra { env[k] = v }
        return env
    }
}

/// One persisted runtime hash-cache record (see
/// `LocalRuntimeDiscovery.cachedExecutableSHA256`): an executable is only re-hashed
/// when its size or mtime drifts — hashing the runtime executable reads tens of MB.
struct RuntimeHashCacheEntry: Codable, Sendable {
    var size: Int64
    var mtime: Double
    var sha256: String
}

/// Harbor-owned discovery only — no hugonote / third-party launcher paths.
public struct LocalRuntimeDiscovery: Sendable {
    public init() {}

    public struct DiscoveredBundle: Sendable {
        public var runtimeInstallation: RuntimeInstallation
        public var gameInstallation: InstalledMinecraft
        public var layout: MCLauncherClientLayout
        public var hasGame: Bool
    }

    /// Test seam: overrides the Harbor support root (nil in production).
    nonisolated(unsafe) static var harborSupportOverride: URL?

    public static var harborSupport: URL {
        harborSupportOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/BedrockHarbor", isDirectory: true)
    }

    /// A runtime root only counts when the sign-in webview can actually start:
    /// mcpelauncher-webview aborts at launch without the Qt cocoa platform plugin,
    /// and without the executable-side qt.conf it cannot resolve its QML modules
    /// (QtQuick.Controls etc.) — both surface in-game as Microsoft login error
    /// Llama (0x80070057).
    public static func isRuntimeRootUsable(_ root: URL) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: root.appendingPathComponent("MacOS/mcpelauncher-client").path) else {
            return false
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("PlugIns/platforms/libqcocoa.dylib").path) else {
            return false
        }
        return fm.fileExists(atPath: root.appendingPathComponent("MacOS/qt.conf").path)
    }

    public static func harborRuntimeRoots() -> [URL] {
        let fm = FileManager.default
        let runtimes = harborSupport.appendingPathComponent("Runtimes", isDirectory: true)
        var roots: [URL] = []
        guard let entries = try? fm.contentsOfDirectory(at: runtimes, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return roots
        }
        for entry in entries where !entry.lastPathComponent.hasPrefix("_") {
            // Correctness gate: every root must pass usability checks at least once
            // per process; roots validated earlier in the same process skip the
            // repeated stats. A new or changed root re-validates, and every process
            // restart starts with an empty validation set.
            if memory.isValidatedRoot(entry) || isRuntimeRootUsable(entry) {
                memory.rememberValidatedRoot(entry)
                roots.append(entry)
            }
        }
        return roots
    }

    public static func gameSearchRoots() -> [URL] {
        [harborSupport.appendingPathComponent("Installations", isDirectory: true)]
    }

    public func discoverDefault() -> DiscoveredBundle? {
        let fm = FileManager.default
        let runtimesDir = Self.harborSupport.appendingPathComponent("Runtimes", isDirectory: true)
        let listing = (try? fm.contentsOfDirectory(atPath: runtimesDir.path))?.sorted() ?? []

        // In-memory fast path: unchanged Runtimes/ listing in this process → reuse the
        // previous bundle; only the executable gets a cheap existence stat.
        if let cached = Self.memory.cachedBundle(runtimesDirectory: runtimesDir, listing: listing),
           fm.isExecutableFile(atPath: cached.layout.executableURL.path) {
            Self.memory.recordCacheHit()
            return cached
        }
        Self.memory.recordCacheMiss()

        guard let runtimeRoot = Self.harborRuntimeRoots().first else { return nil }
        let executable = runtimeRoot.appendingPathComponent("MacOS/mcpelauncher-client")
        guard fm.isExecutableFile(atPath: executable.path) else { return nil }

        let versionLabel = Self.versionLabel(runtimeRoot: runtimeRoot)
        let sha = Self.cachedExecutableSHA256(executable) ?? "unhashed"
        let arch = (try? RuntimeArtifactVerifier().inspectArchitecture(executableURL: executable)) ?? .arm64

        var gameDir: URL?
        var gameName = "unknown"
        var hasGame = false
        for root in Self.gameSearchRoots() {
            if let found = latestGameDirectory(under: root) {
                gameDir = found
                gameName = found.lastPathComponent
                hasGame = fm.fileExists(atPath: found.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so").path)
                break
            }
        }
        let resolvedGame = gameDir
            ?? Self.harborSupport.appendingPathComponent("Installations/missing-game", isDirectory: true)

        let releaseID = "harbor-mcpelauncher-\(versionLabel)"
        let runtime = RuntimeInstallation(
            releaseID: releaseID,
            relativeInstallPath: runtimeRoot.path,
            artifactSHA256: sha,
            health: hasGame && arch == .arm64 || arch == .universal ? .healthy : .degraded,
            verificationNotes: [
                "Harbor private runtime at \(runtimeRoot.path)",
                "architecture=\(arch.rawValue)",
                "source=minecraft-linux macos-builder (not hugonote)",
            ],
            helperGeneration: "harbor-isolated"
        )
        let game = InstalledMinecraft(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: Self.versionCode(fromVersionName: gameName),
                abi: .arm64v8a,
                channel: .release
            ),
            originalVersionName: gameName,
            relativeGameDirectory: resolvedGame.path,
            integrity: hasGame ? .verified : .failed,
            providerID: ProviderID(rawValue: hasGame ? "harbor-install" : "missing-game"),
            packageReceipts: hasGame
                ? [resolvedGame.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so").path]
                : []
        )
        let layout = MCLauncherClientLayout(
            runtimeRootURL: runtimeRoot,
            executableURL: executable,
            gameDirectoryURL: resolvedGame,
            releaseID: releaseID,
            versionLabel: versionLabel,
            modsDirectories: Self.harborModsPaths(gameVersionName: gameName),
            xdgDataDirs: [runtimeRoot.appendingPathComponent("Resources").path],
            forceOpenGLES: true
        )
        let bundle = DiscoveredBundle(runtimeInstallation: runtime, gameInstallation: game, layout: layout, hasGame: hasGame)
        Self.memory.store(bundle: bundle, runtimesDirectory: runtimesDir, listing: listing)
        return bundle
    }

    /// Whether the most recent `discoverDefault()` reused the in-memory bundle cache.
    /// Test hook; not part of the discovery contract.
    static var lastDiscoveryCacheHit: Bool {
        memory.lastCacheHit
    }

    /// Clears the process-local discovery caches (bundle cache + validated roots).
    /// Test hook simulating a fresh process; persisted caches (hash cache) remain.
    static func resetProcessDiscoveryCachesForTesting() {
        memory.reset()
    }

    public static func harborModsPaths(gameVersionName: String) -> [String] {
        let url = harborSupport
            .appendingPathComponent("Patches/\(gameVersionName)/arm64-v8a", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? [url.path] : []
    }

    /// Runtime version label from the root's runtime.json ("v1.8.4-573" fallback).
    static func versionLabel(runtimeRoot: URL) -> String {
        if let data = try? Data(contentsOf: runtimeRoot.appendingPathComponent("runtime.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = obj["version"] as? String {
            return v
        }
        return "v1.8.4-573"
    }

    /// Launch layout for an explicitly chosen runtime root (parameter honoring in
    /// `ProcessLaunchSupervisor.prepareLaunchPlan`): mirrors the layout discovery
    /// builds for its root, with the game directory supplied by the caller.
    static func layout(
        runtimeRoot: URL,
        releaseID: String,
        gameVersionName: String,
        gameDirectory: URL
    ) -> MCLauncherClientLayout {
        MCLauncherClientLayout(
            runtimeRootURL: runtimeRoot,
            executableURL: runtimeRoot.appendingPathComponent("MacOS/mcpelauncher-client"),
            gameDirectoryURL: gameDirectory,
            releaseID: releaseID,
            versionLabel: versionLabel(runtimeRoot: runtimeRoot),
            modsDirectories: harborModsPaths(gameVersionName: gameVersionName),
            xdgDataDirs: [runtimeRoot.appendingPathComponent("Resources").path],
            forceOpenGLES: true
        )
    }

    private func latestGameDirectory(under root: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let hits = entries.filter {
            fm.fileExists(atPath: $0.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so").path)
        }
        return hits.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    public static func versionCode(fromVersionName name: String) -> Int64 {
        let parts = name.split(separator: ".").compactMap { Int64($0) }
        guard !parts.isEmpty else { return 0 }
        var code: Int64 = 0
        for (i, p) in parts.prefix(4).enumerated() { code += p * Int64(pow(1000.0, Double(3 - i))) }
        return code
    }

    // MARK: - Persisted runtime hash cache

    static var runtimeHashCacheURL: URL {
        harborSupport.appendingPathComponent("Metadata/runtime-hash-cache.json", isDirectory: false)
    }

    static func cachedExecutableSHA256(_ executable: URL) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: executable.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return nil }

        var cache: [String: RuntimeHashCacheEntry] = [:]
        if let data = try? Data(contentsOf: runtimeHashCacheURL),
           let decoded = try? JSONDecoder().decode([String: RuntimeHashCacheEntry].self, from: data) {
            cache = decoded
        }
        if let entry = cache[executable.path], entry.size == size, entry.mtime == mtime {
            return entry.sha256
        }
        guard let sha = try? Hashing.sha256Hex(ofFile: executable) else { return nil }
        // Prune entries for executables that no longer exist, then record this one.
        cache = cache.filter { fm.fileExists(atPath: $0.key) }
        cache[executable.path] = RuntimeHashCacheEntry(size: size, mtime: mtime, sha256: sha)
        if let data = try? JSONEncoder().encode(cache) {
            let url = runtimeHashCacheURL
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return sha
    }

    // MARK: - Process-local discovery caches

    /// Lock-guarded process state backing the discovery caches. `discoverDefault()`
    /// stays synchronous (UI and bootstrap call it from nonisolated code), so the
    /// shared state cannot live on an actor.
    private final class DiscoveryMemory: @unchecked Sendable {
        static let shared = DiscoveryMemory()

        private let lock = NSLock()
        private var bundle: DiscoveredBundle?
        private var runtimesDirectory: String = ""
        private var listing: [String] = []
        private var validatedRoots: Set<String> = []
        private var hit = false

        /// Cached bundle when this exact Runtimes/ directory still lists the same
        /// top-level names as the stored discovery.
        func cachedBundle(runtimesDirectory dir: URL, listing now: [String]) -> DiscoveredBundle? {
            lock.lock(); defer { lock.unlock() }
            guard let bundle, dir.path == runtimesDirectory, listing == now else { return nil }
            return bundle
        }

        func store(bundle: DiscoveredBundle, runtimesDirectory dir: URL, listing now: [String]) {
            lock.lock(); defer { lock.unlock() }
            self.bundle = bundle
            self.runtimesDirectory = dir.path
            self.listing = now
        }

        func isValidatedRoot(_ root: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return validatedRoots.contains(root.path)
        }

        func rememberValidatedRoot(_ root: URL) {
            lock.lock(); defer { lock.unlock() }
            validatedRoots.insert(root.path)
        }

        var lastCacheHit: Bool {
            lock.lock(); defer { lock.unlock() }
            return hit
        }

        func recordCacheHit() {
            lock.lock(); hit = true; lock.unlock()
        }

        func recordCacheMiss() {
            lock.lock(); hit = false; lock.unlock()
        }

        func reset() {
            lock.lock()
            bundle = nil
            runtimesDirectory = ""
            listing = []
            validatedRoots = []
            hit = false
            lock.unlock()
        }
    }

    private static let memory = DiscoveryMemory.shared
}

/// Lightweight pre-launch readiness gate: the same helper-resource checks the
/// installer validates at deploy time, re-run as five cheap stats before every
/// launch plan. A runtime damaged after install fails fast with a named remedy
/// instead of dying in-game as a Microsoft login error (Llama 0x80070057).
public enum RuntimeReadiness {
    /// Human-readable names of missing Microsoft sign-in helper resources.
    /// Empty means ready. No caching: called once per `prepareLaunchPlan`.
    public static func missingPieces(runtimeRoot: URL) -> [String] {
        HarborRuntimeInstaller.validateHelperResources(root: runtimeRoot)
    }
}

public actor ProcessLaunchSupervisor: RuntimeLaunching {
    private static let recentSessionLimit = 10

    private var layouts: [String: MCLauncherClientLayout] = [:]
    private var active: [UUID: LaunchSession] = [:]
    private var processes: [UUID: Process] = [:]
    private var writers: [UUID: ProcessLogWriter] = [:]
    private var stopRequested: Set<UUID> = []
    private var recentSessions: [LaunchSession] = []
    private let paths: HarborPaths
    /// The recorder that owns the in-flight `launch` timing session (begun in
    /// `start(plan:)`). Public so the UI layer can add window-appearance marks
    /// — game window, Microsoft sign-in window — into the same session.
    public nonisolated let launchTiming: LaunchTimingRecorder
    private let hub = SessionEventHub()

    public init(paths: HarborPaths) {
        self.paths = paths
        // Timing is diagnostics-only and records one in-flight session at a time;
        // Harbor launches one game session at a time, so this matches reality.
        self.launchTiming = LaunchTimingRecorder(directory: paths.metadataDirectory)
    }

    public func registerLayout(_ layout: MCLauncherClientLayout) {
        layouts[layout.releaseID] = layout
    }

    public func prepareLaunchPlan(
        profile: Profile,
        installation: InstalledMinecraft,
        runtime: RuntimeInstallation
    ) async throws -> LaunchPlan {
        let fm = FileManager.default
        let discovery = LocalRuntimeDiscovery().discoverDefault()
        if let bundle = discovery { registerLayout(bundle.layout) }

        // Honor the caller's installation: the profile-selected game wins whenever its
        // package is actually on disk and not known-failed. Discovery's newest-game
        // scan is a fallback only — it used to override the selection silently.
        let callerGameDir = URL(fileURLWithPath: installation.relativeGameDirectory, isDirectory: true)
        let callerGameLibOnDisk = fm.fileExists(
            atPath: callerGameDir.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so").path
        )
        let game: InstalledMinecraft
        if installation.integrity != .failed && callerGameLibOnDisk {
            game = installation
        } else if let bundle = discovery, bundle.gameInstallation.integrity == .verified {
            game = bundle.gameInstallation
        } else {
            game = installation
        }

        // Honor the caller's runtime: its root wins when it passes the cheap usability
        // checks; discovery's first root is a fallback only.
        let callerRuntimeRoot = URL(fileURLWithPath: runtime.relativeInstallPath, isDirectory: true)
        let useCallerRuntime = LocalRuntimeDiscovery.isRuntimeRootUsable(callerRuntimeRoot)

        let chosenRuntime: RuntimeInstallation
        let baseLayout: MCLauncherClientLayout
        if useCallerRuntime,
           let bundle = discovery,
           bundle.layout.runtimeRootURL.standardizedFileURL == callerRuntimeRoot.standardizedFileURL {
            chosenRuntime = runtime
            baseLayout = bundle.layout
        } else if useCallerRuntime {
            chosenRuntime = runtime
            // A registered layout for this releaseID may be discovery's for a
            // same-named release at a DIFFERENT root (releaseID carries no path), so
            // reuse it only when it really is the caller's root and its executable is
            // still there; otherwise build fresh from the caller's root.
            if let registered = layouts[runtime.releaseID],
               registered.runtimeRootURL.standardizedFileURL == callerRuntimeRoot.standardizedFileURL,
               fm.isExecutableFile(atPath: registered.executableURL.path) {
                baseLayout = registered
            } else {
                let built = LocalRuntimeDiscovery.layout(
                    runtimeRoot: callerRuntimeRoot,
                    releaseID: runtime.releaseID,
                    gameVersionName: game.originalVersionName,
                    gameDirectory: callerGameDir
                )
                registerLayout(built)
                baseLayout = built
            }
        } else if let bundle = discovery {
            chosenRuntime = bundle.runtimeInstallation
            baseLayout = bundle.layout
        } else if let layout = layouts[runtime.releaseID],
                  fm.isExecutableFile(atPath: layout.executableURL.path) {
            chosenRuntime = runtime
            baseLayout = layout
        } else {
            throw HarborError.unsupportedRuntime(
                reason: "No Harbor private runtime under Application Support/BedrockHarbor/Runtimes"
            )
        }

        // The plan's -dg (game directory) must follow the honored game, not whichever
        // game directory discovery happened to find.
        var layout = baseLayout
        layout.gameDirectoryURL = URL(fileURLWithPath: game.relativeGameDirectory, isDirectory: true)

        return try await makePlan(profile: profile, installation: game, runtime: chosenRuntime, layout: layout)
    }

    private func makePlan(
        profile: Profile,
        installation: InstalledMinecraft,
        runtime: RuntimeInstallation,
        layout: MCLauncherClientLayout
    ) async throws -> LaunchPlan {
        // Pre-launch readiness: five cheap stats per plan. Refuse before any
        // directory or compatibility work so a broken runtime fails fast with
        // the reinstall remedy.
        let missingHelperResources = RuntimeReadiness.missingPieces(runtimeRoot: layout.runtimeRootURL)
        if !missingHelperResources.isEmpty {
            throw HarborError.unsupportedRuntime(
                reason: "Runtime is missing Microsoft sign-in resources: "
                    + missingHelperResources.joined(separator: ", ")
                    + " — Settings → Runtime → Reinstall the launcher runtime"
            )
        }
        try paths.ensurePrivateDirectoryLayout()
        let root = paths.gameDataDirectory.appendingPathComponent(profile.dataRootID, isDirectory: true)
        let cache = paths.gameCache.appendingPathComponent(profile.dataRootID, isDirectory: true)
        for rel in [
            "games/com.mojang", "minecraftpe", "proc", "sys", "cache",
            "premium_cache", "treatments", "xal", "Flighting",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(rel, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        var environment = layout.launchEnvironment()
        environment["BH_SESSION_PROFILE"] = profile.id.uuidString
        environment["BH_SESSION_RUNTIME"] = runtime.releaseID

        // Official mcpelauncher-updates compatibility mod (same public moddb as other launchers).
        // For game generations where that mod is verified broken, preparation applies
        // Harbor's compat stack instead and returns nil (no mod directory on `-m`).
        // Repeat launches of an unchanged configuration skip the heavy work via the
        // preparation receipt (prepareForLaunchDetailed).
        var compatibilityPatchURL: URL?
        let gameURL = URL(fileURLWithPath: installation.relativeGameDirectory, isDirectory: true)
        do {
            compatibilityPatchURL = try await HarborCompatibilityPatches.prepareForLaunchDetailed(
                gameDirectory: gameURL,
                versionName: installation.originalVersionName,
                versionCode: installation.buildID.versionCode,
                runtimeRoot: layout.runtimeRootURL
            ).modDirectory
        } catch let error as HarborError {
            // A game version positively known to be unrunnable must not launch; patch-fetch
            // failures degrade to launching without the mod.
            if case .compatibilityBlocked = error { throw error }
            compatibilityPatchURL = nil
        } catch {
            compatibilityPatchURL = nil
        }
        if let patch = compatibilityPatchURL {
            environment["BH_COMPAT_PATCH"] = patch.path
        }

        // prepareForLaunch may have JUST installed the symbol shim into Patches/<version>/,
        // after the layout captured modsDirectories at discovery time — re-resolve from disk
        // so the first launch after a wipe also passes the shim via -m.
        var effectiveLayout = layout
        effectiveLayout.modsDirectories = LocalRuntimeDiscovery.harborModsPaths(
            gameVersionName: installation.originalVersionName
        )

        return LaunchPlan(
            executableURL: effectiveLayout.executableURL,
            arguments: effectiveLayout.arguments(
                dataDirectory: root,
                cacheDirectory: cache,
                compatibilityPatchPath: compatibilityPatchURL
            ),
            workingDirectoryURL: effectiveLayout.preferredWorkingDirectory,
            environment: environment,
            gameDataDirectoryURL: root,
            cacheDirectoryURL: cache,
            profileID: profile.id,
            installationID: installation.id,
            runtimeReleaseID: runtime.releaseID
        )
    }

    public func start(plan: LaunchPlan) async throws -> LaunchSession {
        guard FileManager.default.isExecutableFile(atPath: plan.executableURL.path) else {
            throw HarborError.unsupportedRuntime(reason: "Executable missing: \(plan.executableURL.path)")
        }
        try paths.ensurePrivateDirectoryLayout()
        try FileManager.default.createDirectory(at: paths.sessionLogs, withIntermediateDirectories: true)
        let sessionID = UUID()
        await launchTiming.begin(kind: "launch", runtimeRelease: plan.runtimeReleaseID)
        let logURL = paths.sessionLogs.appendingPathComponent("session-\(sessionID.uuidString).log")
        var session = LaunchSession(
            id: sessionID,
            profileID: plan.profileID,
            installationID: plan.installationID,
            runtimeReleaseID: plan.runtimeReleaseID,
            state: .starting,
            logRelativePath: logURL.lastPathComponent
        )
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectoryURL
        var env = plan.environment
        env["BH_SESSION_ID"] = sessionID.uuidString
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            await launchTiming.end(outcome: "failed")
            throw HarborError.unsupportedRuntime(reason: "Process failed to start: \(error.localizedDescription)")
        }
        session.state = .running
        session.processIdentifier = process.processIdentifier
        session.startedAt = Date()
        active[sessionID] = session
        processes[sessionID] = process
        await launchTiming.mark(.processLaunched)

        // Nonblocking IO: handlers run on dispatch queues, never on this actor
        // or the cooperative pool.
        let writer = ProcessLogWriter(fileURL: logURL)
        writers[sessionID] = writer
        ProcessPipeDrainer.drain(out.fileHandleForReading, writer: writer, tag: "stdout")
        ProcessPipeDrainer.drain(err.fileHandleForReading, writer: writer, tag: "stderr")

        // Termination is observed via the handler (invoked even when set after a
        // super-fast exit); it hops back here with Sendable values only.
        // NO waitUntilExit() anywhere — that would block a cooperative thread.
        process.terminationHandler = { @Sendable exited in
            let status = exited.terminationStatus
            let reason = exited.terminationReason
            Task { await self.noteExit(sessionID: sessionID, code: status, reason: reason) }
        }

        let pid = process.processIdentifier
        await hub.emit(RuntimeEvent(sessionID: sessionID, kind: .started, message: "pid \(pid)"))
        await hub.emit(RuntimeEvent(sessionID: sessionID, kind: .running))
        return session
    }

    /// Terminal-state mapping (documented choice per task brief):
    /// - exit code 0 → `.exited` / `"ok"`
    /// - nonzero exit → `.failed` / `"failed"`
    /// - uncaught signal after `requestTermination` (SIGTERM from our `terminate()`)
    ///   → `.exited` / `"cancelled"`: the exit was requested by the user, not a crash
    /// - uncaught signal without a requested stop → `.failed` / `"failed"`: the game died
    private func noteExit(sessionID: UUID, code: Int32, reason: Process.TerminationReason) async {
        let requestedStop = stopRequested.remove(sessionID) != nil
        if var s = active[sessionID] {
            s.endedAt = Date()
            s.exitCode = code
            if reason == .uncaughtSignal {
                s.terminationSignal = code
                s.state = requestedStop ? .exited : .failed
            } else {
                s.state = code == 0 ? .exited : .failed
            }
            active[sessionID] = s

            recentSessions.append(s)
            if recentSessions.count > Self.recentSessionLimit {
                recentSessions.removeFirst(recentSessions.count - Self.recentSessionLimit)
            }
            await hub.retainOnly(Set(recentSessions.map(\.id)))

            await launchTiming.mark(.sessionEnded)
            await launchTiming.end(outcome: requestedStop ? "cancelled" : (s.state == .exited ? "ok" : "failed"))
            await hub.emit(
                RuntimeEvent(
                    sessionID: sessionID,
                    kind: s.state == .exited ? .exited : .failed,
                    exitCode: code,
                    message: reason == .uncaughtSignal
                        ? "signal \(code)\(requestedStop ? " (stop requested)" : "")"
                        : "exit \(code)"
                )
            )
        }
        // Closing here may drop output still buffered in the pipes (≤ pipe
        // capacity); descendant processes holding the write end would otherwise
        // keep the fd open forever. `close()` is idempotent either way.
        writers.removeValue(forKey: sessionID)?.close()
        processes.removeValue(forKey: sessionID)
        active.removeValue(forKey: sessionID)
    }

    public nonisolated func events(sessionID: UUID) -> AsyncStream<RuntimeEvent> {
        AsyncStream { continuation in
            let subscriberID = UUID()
            continuation.onTermination = { @Sendable _ in
                Task { await self.hub.unsubscribe(sessionID, subscriberID: subscriberID) }
            }
            Task { await self.hub.subscribe(sessionID, subscriberID: subscriberID, continuation: continuation) }
        }
    }

    public func requestTermination(sessionID: UUID) async throws {
        guard processes[sessionID] != nil, active[sessionID] != nil else { return }
        // `terminate()` (SIGTERM) is preferred over `interrupt()` (SIGINT): SIGTERM
        // is the standard polite-shutdown signal and mcpelauncher handles it as a
        // normal stop. noteExit maps the resulting uncaughtSignal to `.exited`
        // because the stop originated here.
        stopRequested.insert(sessionID)
        if var s = active[sessionID] {
            s.state = .terminationRequested
            active[sessionID] = s
        }
        await hub.emit(RuntimeEvent(sessionID: sessionID, kind: .stopping, message: "terminate requested"))
        if let p = processes[sessionID], p.isRunning { p.terminate() }
    }
}

/// Fan-out hub for `RuntimeEvent`s. Supports multiple simultaneous
/// subscribers per session (the coordinator's lease-release observer plus any
/// UI listeners): every live subscriber receives every event, and a terminal
/// event is delivered to all of them and finishes every stream. Keeps a
/// bounded per-session history so a subscriber attaching after a super-fast
/// exit still sees the full sequence, and finishes streams for finished or
/// unknown sessions so `events(sessionID:)` can never hang. The FIRST terminal
/// event is authoritative: later emits for that session are ignored, so a
/// finished session can never look live again (e.g. under reordered emission).
actor SessionEventHub {
    private struct Subscriber {
        let id: UUID
        let continuation: AsyncStream<RuntimeEvent>.Continuation
    }

    private var subscribers: [UUID: [Subscriber]] = [:]
    private var history: [UUID: [RuntimeEvent]] = [:]

    private static func isTerminal(_ event: RuntimeEvent) -> Bool {
        event.kind == .exited || event.kind == .failed
    }

    func subscribe(
        _ sessionID: UUID,
        subscriberID: UUID,
        continuation: AsyncStream<RuntimeEvent>.Continuation
    ) {
        guard let events = history[sessionID] else {
            // Unknown session: nothing to replay, nothing will ever arrive.
            continuation.finish()
            return
        }
        for event in events { continuation.yield(event) }
        // "Contains terminal" (not "last is terminal") — see emit(_:).
        if events.contains(where: Self.isTerminal) {
            continuation.finish()
            return
        }
        subscribers[sessionID, default: []].append(Subscriber(id: subscriberID, continuation: continuation))
    }

    /// Removes exactly one subscriber; other subscribers of the session
    /// (registered before or after this one) keep receiving events.
    func unsubscribe(_ sessionID: UUID, subscriberID: UUID) {
        subscribers[sessionID]?.removeAll { $0.id == subscriberID }
    }

    func emit(_ event: RuntimeEvent) {
        var events = history[event.sessionID] ?? []
        guard !events.contains(where: Self.isTerminal) else {
            return // already finished: the first terminal stays authoritative
        }
        events.append(event)
        history[event.sessionID] = events

        let live = subscribers[event.sessionID] ?? []
        if Self.isTerminal(event) {
            subscribers.removeValue(forKey: event.sessionID)
        }
        for subscriber in live {
            subscriber.continuation.yield(event)
            if Self.isTerminal(event) { subscriber.continuation.finish() }
        }
    }

    /// Drops history for sessions that fell out of the supervisor's
    /// `recentSessions` window.
    func retainOnly(_ sessionIDs: Set<UUID>) {
        for id in history.keys where !sessionIDs.contains(id) {
            history.removeValue(forKey: id)
            subscribers.removeValue(forKey: id)
        }
    }
}

public actor InMemoryRuntimeProvider: RuntimeProviding {
    public func discoverInstallations() async throws -> [RuntimeInstallation] {
        LocalRuntimeDiscovery().discoverDefault().map { [$0.runtimeInstallation] } ?? []
    }
    public func approvedReleases() async throws -> [RuntimeRelease] { [] }
    public func install(release: RuntimeRelease, artifactURL: URL) async throws -> RuntimeInstallation {
        throw HarborError.unsupportedOperation(reason: "Use Harbor private runtime deployment")
    }
    public func health(for installationID: UUID) async throws -> RuntimeHealth { .unknown }
}

public actor LocalRuntimeProvider: RuntimeProviding {
    public init() {}
    public func discoverInstallations() async throws -> [RuntimeInstallation] {
        LocalRuntimeDiscovery().discoverDefault().map { [$0.runtimeInstallation] } ?? []
    }
    public func approvedReleases() async throws -> [RuntimeRelease] { [] }
    public func install(release: RuntimeRelease, artifactURL: URL) async throws -> RuntimeInstallation {
        throw HarborError.unsupportedOperation(reason: "Runtime install via Scripts/install_local_runtime.sh")
    }
    public func health(for installationID: UUID) async throws -> RuntimeHealth { .unknown }
}
