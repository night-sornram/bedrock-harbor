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

    public init() {}

    public static func harborInstallRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BedrockHarbor/Installations", isDirectory: true)
    }

    /// Roots scanned automatically (Harbor-owned first, then common local leftovers).
    public static func scanRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            harborInstallRoot(),
            support.appendingPathComponent("Minecraft Bedrock Launcher/game-versions", isDirectory: true),
            support.appendingPathComponent("mcpelauncher/versions", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
        ]
    }

    public static func findGamePackages(limit: Int = 8) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for root in scanRoots() {
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

    /// Copy a discovered package into Harbor Installations and return a verified record.
    public static func importIntoHarbor(from source: URL, services: HarborServiceBundle) async throws -> InstalledMinecraft {
        let fm = FileManager.default
        let lib = source.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so")
        guard fm.fileExists(atPath: lib.path) else {
            throw HarborError.invalidPackage(reason: "Not a Bedrock package: \(source.path)")
        }
        let versionName = source.lastPathComponent
        let dest = harborInstallRoot().appendingPathComponent(versionName, isDirectory: true)
        try fm.createDirectory(at: harborInstallRoot(), withIntermediateDirectories: true)
        if !source.standardizedFileURL.path.hasPrefix(harborInstallRoot().path) {
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

        let process = Process()
        process.executableURL = extractor
        process.arguments = [apk.path, dest.path]
        process.currentDirectoryURL = dest
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        let lib = dest.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so")
        guard process.terminationStatus == 0, fm.fileExists(atPath: lib.path) else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw HarborError.invalidPackage(reason: "APK extract failed (status \(process.terminationStatus)): \(msg)")
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
    public static func acquire(services: HarborServiceBundle) async -> Result {
        let existing = (try? await services.metadata.loadInstallations()) ?? []
        if let verified = existing.first(where: { $0.integrity == .verified }),
           FileManager.default.fileExists(
               atPath: URL(fileURLWithPath: verified.relativeGameDirectory)
                   .appendingPathComponent("lib/arm64-v8a/libminecraftpe.so").path
           ) {
            return Result(installation: verified, message: "Using verified package \(verified.originalVersionName)", didImport: false)
        }

        let candidates = findGamePackages()
        for gameDir in candidates {
            do {
                let install = try await importIntoHarbor(from: gameDir, services: services)
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
            message: "No Minecraft package on this Mac yet. Download once in Minecraft Bedrock Launcher (Google Play), or import an owned APK/folder. Harbor Play client cannot fetch APKs from Google right now.",
            didImport: false
        )
    }
}
