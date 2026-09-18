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

/// Harbor-owned discovery only — no hugonote / third-party launcher paths.
public struct LocalRuntimeDiscovery: Sendable {
    public init() {}

    public struct DiscoveredBundle: Sendable {
        public var runtimeInstallation: RuntimeInstallation
        public var gameInstallation: InstalledMinecraft
        public var layout: MCLauncherClientLayout
        public var hasGame: Bool
    }

    public static var harborSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
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
            if isRuntimeRootUsable(entry) { roots.append(entry) }
        }
        return roots
    }

    public static func gameSearchRoots() -> [URL] {
        [harborSupport.appendingPathComponent("Installations", isDirectory: true)]
    }

    public func discoverDefault() -> DiscoveredBundle? {
        let fm = FileManager.default
        guard let runtimeRoot = Self.harborRuntimeRoots().first else { return nil }
        let executable = runtimeRoot.appendingPathComponent("MacOS/mcpelauncher-client")
        guard fm.isExecutableFile(atPath: executable.path) else { return nil }

        var versionLabel = "v1.8.4-573"
        if let data = try? Data(contentsOf: runtimeRoot.appendingPathComponent("runtime.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = obj["version"] as? String {
            versionLabel = v
        }
        let sha = (try? Hashing.sha256Hex(ofFile: executable)) ?? "unhashed"
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
        return DiscoveredBundle(runtimeInstallation: runtime, gameInstallation: game, layout: layout, hasGame: hasGame)
    }

    public static func harborModsPaths(gameVersionName: String) -> [String] {
        let url = harborSupport
            .appendingPathComponent("Patches/\(gameVersionName)/arm64-v8a", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? [url.path] : []
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
}

public actor ProcessLaunchSupervisor: RuntimeLaunching {
    private var layouts: [String: MCLauncherClientLayout] = [:]
    private var active: [UUID: LaunchSession] = [:]
    private var processes: [UUID: Process] = [:]
    private let paths: HarborPaths

    public init(paths: HarborPaths) { self.paths = paths }

    public func registerLayout(_ layout: MCLauncherClientLayout) {
        layouts[layout.releaseID] = layout
    }

    public func prepareLaunchPlan(
        profile: Profile,
        installation: InstalledMinecraft,
        runtime: RuntimeInstallation
    ) async throws -> LaunchPlan {
        if let bundle = LocalRuntimeDiscovery().discoverDefault() {
            await registerLayout(bundle.layout)
            let install = bundle.gameInstallation.integrity == .verified ? bundle.gameInstallation : installation
            return try await makePlan(profile: profile, installation: install, runtime: bundle.runtimeInstallation, layout: bundle.layout)
        }
        if let layout = layouts[runtime.releaseID],
           FileManager.default.isExecutableFile(atPath: layout.executableURL.path) {
            return try await makePlan(profile: profile, installation: installation, runtime: runtime, layout: layout)
        }
        throw HarborError.unsupportedRuntime(
            reason: "No Harbor private runtime under Application Support/BedrockHarbor/Runtimes"
        )
    }

    private func makePlan(
        profile: Profile,
        installation: InstalledMinecraft,
        runtime: RuntimeInstallation,
        layout: MCLauncherClientLayout
    ) async throws -> LaunchPlan {
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
        // For game generations where that mod is verified broken, prepareForLaunch applies
        // Harbor's compat stack instead and returns nil (no mod directory on `-m`).
        var compatibilityPatchURL: URL?
        let gameURL = URL(fileURLWithPath: installation.relativeGameDirectory, isDirectory: true)
        do {
            compatibilityPatchURL = try await HarborCompatibilityPatches.prepareForLaunch(
                gameDirectory: gameURL,
                versionName: installation.originalVersionName,
                versionCode: installation.buildID.versionCode,
                runtimeRoot: layout.runtimeRootURL
            )
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
            session.state = .failed
            throw HarborError.unsupportedRuntime(reason: "Process failed to start: \(error.localizedDescription)")
        }
        session.state = .running
        session.processIdentifier = process.processIdentifier
        session.startedAt = Date()
        active[sessionID] = session
        processes[sessionID] = process
        Task.detached { await self.drain(out, to: logURL, tag: "stdout") }
        Task.detached { await self.drain(err, to: logURL, tag: "stderr") }
        Task.detached {
            process.waitUntilExit()
            await self.noteExit(sessionID: sessionID, code: process.terminationStatus, reason: process.terminationReason)
        }
        return session
    }

    private func drain(_ pipe: Pipe, to logURL: URL, tag: String) async {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        let read = pipe.fileHandleForReading
        while true {
            let chunk = read.availableData
            if chunk.isEmpty { break }
            if let data = "[\(tag)] ".data(using: .utf8) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.write(contentsOf: chunk)
            }
        }
    }

    private func noteExit(sessionID: UUID, code: Int32, reason: Process.TerminationReason) {
        if var s = active[sessionID] {
            s.endedAt = Date()
            s.exitCode = code
            s.state = reason == .uncaughtSignal ? .terminated : (code == 0 ? .exited : .failed)
        }
        processes.removeValue(forKey: sessionID)
        active.removeValue(forKey: sessionID)
    }

    public nonisolated func events(sessionID: UUID) -> AsyncStream<LaunchSessionState> {
        AsyncStream { $0.finish() }
    }

    public func requestTermination(sessionID: UUID) async throws {
        if let p = processes[sessionID], p.isRunning { p.interrupt() }
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
