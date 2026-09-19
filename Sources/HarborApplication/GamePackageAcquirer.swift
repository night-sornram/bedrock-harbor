import Foundation
import HarborDomain
import HarborPlatform

/// Acquires Minecraft packages into Harbor-owned Installations without asking the user
/// to copy files by hand. Prefers an existing verified install, then auto-imports any
/// arm64 package found on disk, then reports if provider download is still required.
public struct GamePackageAcquirer: Sendable {
    public struct Result: Sendable {
        public var installation: InstalledMinecraft?
        public var message: String
        public var didImport: Bool
    }

    /// How much of the disk `acquire` is allowed to look at.
    /// - `startup`: app bootstrap — Harbor-owned Installations root only, never a
    ///   recursive walk of ~/Downloads or ~/Desktop (slow on real desktops).
    /// - `full`: explicit user action (Rescan packages) — all roots, recursive.
    public enum ScanScope {
        case startup
        case full
    }

    public init() {}

    public static func harborInstallRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/BedrockHarbor/Installations", isDirectory: true)
    }

    /// Roots scanned automatically (Harbor-owned first, then common local leftovers).
    public static func scanRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            harborInstallRoot(home: home),
            support.appendingPathComponent("Minecraft Bedrock Launcher/game-versions", isDirectory: true),
            support.appendingPathComponent("mcpelauncher/versions", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
        ]
    }

    public static func findGamePackages(roots: [URL], limit: Int = 8) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.lastPathComponent == "libminecraftpe.so",
                   url.path.hasSuffix("lib/arm64-v8a/libminecraftpe.so") {
                    // Parent of lib/arm64-v8a is the game directory
                    let gameDir = url
                        .deletingLastPathComponent() // arm64-v8a
                        .deletingLastPathComponent() // lib
                        .deletingLastPathComponent() // game root
                    if !found.contains(gameDir) {
                        found.append(gameDir)
                    }
                    if found.count >= limit { return found }
                }
            }
        }
        return found
    }

    /// Startup-shaped scan: non-recursive listing of the version directories in
    /// Harbor's own Installations root, each checked for the arm64 game library.
    /// Never descends into Desktop/Downloads/other-launcher directories.
    public static func findStartupGamePackages(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let fm = FileManager.default
        let root = harborInstallRoot(home: home)
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so").path) }
    }

    /// Copy a discovered package into Harbor Installations and return a verified record.
    public static func importIntoHarbor(
        from source: URL,
        services: HarborServiceBundle,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> InstalledMinecraft {
        let fm = FileManager.default
        let lib = source.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so")
        guard fm.fileExists(atPath: lib.path) else {
            throw HarborError.invalidPackage(reason: "Not a Bedrock package: \(source.path)")
        }
        let versionName = source.lastPathComponent
        let installRoot = harborInstallRoot(home: home)
        let dest = installRoot.appendingPathComponent(versionName, isDirectory: true)
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        if !source.standardizedFileURL.path.hasPrefix(installRoot.path) {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dest.path)

        var parts = versionName.split(separator: ".").compactMap { Int64($0) }
        if parts.isEmpty { parts = [0] }
        var code: Int64 = 0
        for (i, p) in parts.prefix(4).enumerated() { code += p * Int64(pow(1000.0, Double(3 - i))) }

        let install = InstalledMinecraft(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: code,
                abi: .arm64v8a,
                channel: .release
            ),
            originalVersionName: versionName,
            relativeGameDirectory: dest.path,
            integrity: .verified,
            providerID: ProviderID(rawValue: "harbor-auto-import"),
            packageReceipts: [dest.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so").path]
        )

        var all = (try? await services.metadata.loadInstallations()) ?? []
        all.removeAll { $0.relativeGameDirectory == dest.path || $0.providerID.rawValue == "missing-game" }
        all.append(install)
        try await services.metadata.saveInstallations(all)

        var profiles = (try? await services.metadata.loadProfiles()) ?? []
        if var first = profiles.first {
            first.selectedInstallationID = install.id
            profiles[0] = first
            try await services.metadata.saveProfiles(profiles)
        }
        return install
    }

    public static func extractAPK(_ apk: URL, services: HarborServiceBundle) async throws -> InstalledMinecraft {
        let fm = FileManager.default
        let versionName = apk.deletingPathExtension().lastPathComponent
        let dest = harborInstallRoot().appendingPathComponent(versionName, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let runtimes = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BedrockHarbor/Runtimes", isDirectory: true)
        var extractor: URL?
        if let entries = try? fm.contentsOfDirectory(at: runtimes, includingPropertiesForKeys: nil) {
            for entry in entries {
                let tool = entry.appendingPathComponent("MacOS/mcpelauncher-extract")
                if fm.isExecutableFile(atPath: tool.path) {
                    extractor = tool
                    break
                }
            }
        }
        guard let extractor else {
            throw HarborError.unsupportedRuntime(reason: "mcpelauncher-extract not found in BedrockHarbor/Runtimes")
        }

        let extract = try await HarborSubprocess.run(
            executable: extractor,
            arguments: [apk.path, dest.path],
            currentDirectory: dest
        )

        let lib = dest.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so")
        guard extract.exitCode == 0, !extract.timedOut, fm.fileExists(atPath: lib.path) else {
            // stderr is capped at the first 64 KB — enough to diagnose, never a firehose.
            throw HarborError.invalidPackage(reason: "APK extract failed (status \(extract.exitCode)): \(extract.stderr)")
        }

        var parts = versionName.split(separator: ".").compactMap { Int64($0) }
        if parts.isEmpty { parts = [0] }
        var code: Int64 = 0
        for (i, p) in parts.prefix(4).enumerated() { code += p * Int64(pow(1000.0, Double(3 - i))) }

        let install = InstalledMinecraft(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: code,
                abi: .arm64v8a,
                channel: .release
            ),
            originalVersionName: versionName,
            relativeGameDirectory: dest.path,
            integrity: .verified,
            providerID: ProviderID(rawValue: "harbor-apk-extract"),
            packageReceipts: [lib.path]
        )
        var all = (try? await services.metadata.loadInstallations()) ?? []
        all.removeAll { $0.relativeGameDirectory == dest.path || $0.providerID.rawValue == "missing-game" }
        all.append(install)
        try await services.metadata.saveInstallations(all)
        var profiles = (try? await services.metadata.loadProfiles()) ?? []
        for i in profiles.indices {
            profiles[i].selectedInstallationID = install.id
        }
        try await services.metadata.saveProfiles(profiles)
        return install
    }

    /// Main entry: make Launch possible without manual file operations.
    /// `scope` limits the disk scan: `.startup` (bootstrap) never walks
    /// ~/Downloads or ~/Desktop; `.full` is reserved for explicit user intent.
    public static func acquire(
        services: HarborServiceBundle,
        scope: ScanScope = .full,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> Result {
        let existing = (try? await services.metadata.loadInstallations()) ?? []
        if let verified = existing.first(where: { $0.integrity == .verified }),
           FileManager.default.fileExists(
               atPath: URL(fileURLWithPath: verified.relativeGameDirectory)
                   .appendingPathComponent("lib/arm64-v8a/libminecraftpe.so").path
           ) {
            return Result(installation: verified, message: "Using verified package \(verified.originalVersionName)", didImport: false)
        }

        let candidates: [URL]
        switch scope {
        case .startup:
            candidates = findStartupGamePackages(home: home)
        case .full:
            candidates = findGamePackages(roots: scanRoots(home: home))
        }
        for gameDir in candidates {
            do {
                let install = try await importIntoHarbor(from: gameDir, services: services, home: home)
                return Result(
                    installation: install,
                    message: "Auto-imported \(install.originalVersionName) into BedrockHarbor/Installations",
                    didImport: true
                )
            } catch {
                continue
            }
        }

        return Result(
            installation: nil,
            message: "No Minecraft package on this Mac yet. Sign in with Google Play and press Install Minecraft — Harbor downloads it from Google directly. An owned APK/folder can also be imported.",
            didImport: false
        )
    }
}
