import Foundation
import HarborApplication
import HarborDomain
import HarborPlatform
import HarborRuntime

public enum LocalLaunchBootstrap {
    public static func seedGameDataRoot(_ url: URL) throws {
        let fm = FileManager.default
        for rel in [
            "games/com.mojang", "minecraftpe", "proc", "sys", "cache",
            "files", "databases", "shared_prefs", "no_backup", "internal",
            "premium_cache", "treatments", "xal", "Flighting", "PackManifestFactoryCache",
        ] {
            try fm.createDirectory(at: url.appendingPathComponent(rel, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    @discardableResult
    public static func prepareIfNeeded(
        services: HarborServiceBundle,
        launcher: ProcessLaunchSupervisor
    ) async throws -> String {
        try services.paths.ensurePrivateDirectoryLayout()
        guard let bundle = LocalRuntimeDiscovery().discoverDefault() else {
            throw HarborError.unsupportedRuntime(
                reason: "No runtime in BedrockHarbor/Runtimes. Run Scripts/install_local_runtime.sh first."
            )
        }
        await launcher.registerLayout(bundle.layout)

        var runtimes = (try? await services.metadata.loadRuntimeInstallations()) ?? []
        if let i = runtimes.firstIndex(where: { $0.releaseID == bundle.runtimeInstallation.releaseID }) {
            runtimes[i] = bundle.runtimeInstallation
        } else {
            runtimes.append(bundle.runtimeInstallation)
        }
        try await services.metadata.saveRuntimeInstallations(runtimes)

        var installs = (try? await services.metadata.loadInstallations()) ?? []
        installs.removeAll { $0.providerID.rawValue == "missing-game" }
        if bundle.hasGame {
            if let i = installs.firstIndex(where: { $0.relativeGameDirectory == bundle.gameInstallation.relativeGameDirectory }) {
                installs[i] = bundle.gameInstallation
            } else {
                installs.append(bundle.gameInstallation)
            }
        }
        try await services.metadata.saveInstallations(installs)

        var profiles = (try? await services.metadata.loadProfiles()) ?? []
        let installation = installs.first {
            $0.relativeGameDirectory == bundle.gameInstallation.relativeGameDirectory && bundle.hasGame
        }
        if profiles.isEmpty {
            let p = Profile(
                name: "Default",
                selectedInstallationID: installation?.id,
                pinnedRuntimeReleaseID: bundle.runtimeInstallation.releaseID
            )
            profiles.append(p)
            try await services.metadata.saveProfiles(profiles)
        } else if var first = profiles.first {
            first.selectedInstallationID = installation?.id
            first.pinnedRuntimeReleaseID = bundle.runtimeInstallation.releaseID
            profiles[0] = first
            try await services.metadata.saveProfiles(profiles)
        }

        for profile in profiles {
            let data = services.paths.gameDataDirectory
                .appendingPathComponent(profile.dataRootID, isDirectory: true)
            try seedGameDataRoot(data)
        }

        // Auto-acquire game package into Harbor Installations (no manual user step).
        let acquire = await GamePackageAcquirer.acquire(services: services)
        if let install = acquire.installation {
            var profs = (try? await services.metadata.loadProfiles()) ?? []
            if var first = profs.first {
                first.selectedInstallationID = install.id
                first.pinnedRuntimeReleaseID = bundle.runtimeInstallation.releaseID
                profs[0] = first
                try? await services.metadata.saveProfiles(profs)
            }
        }

        if acquire.didImport, let install = acquire.installation {
            return "Runtime ready · \(acquire.message) · Launch should work"
        }
        if acquire.installation != nil {
            return "Runtime ready · \(acquire.message)"
        }
        return acquire.message
    }
}
