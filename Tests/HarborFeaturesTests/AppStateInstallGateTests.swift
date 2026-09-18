import Foundation
import Testing
@testable import HarborFeatures
import HarborApplication
import HarborCompatibility
import HarborDomain
import HarborPlatform

@MainActor
@Suite("AppState install gate")
struct AppStateInstallGateTests {
    private func makeServices() throws -> HarborServiceBundle {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-features-\(UUID().uuidString)", isDirectory: true)
        let paths = HarborPaths(
            applicationSupportRoot: base.appendingPathComponent("Support", isDirectory: true),
            cachesRoot: base.appendingPathComponent("Caches", isDirectory: true),
            logsRoot: base.appendingPathComponent("Logs", isDirectory: true)
        )
        try paths.ensurePrivateDirectoryLayout()
        return HarborServiceBundle(
            metadata: InMemoryMetadataRepository(),
            credentials: InMemoryCredentialStore(),
            store: UnavailableStoreProvider(),
            runtimeProvider: PlaceholderRuntimeProvider(),
            runtimeLauncher: PlaceholderRuntimeLauncher(),
            compatibility: RulesetEvaluator(),
            paths: paths
        )
    }

    /// A verified record whose game files are gone on disk must NOT count as
    /// installed — otherwise Harbor keeps showing the Install step for a game
    /// that is really there (or claims ready for one that isn't).
    @Test func verifiedGameRequiresReceiptOnDisk() async throws {
        let services = try makeServices()
        let gameDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-game-\(UUID().uuidString)", isDirectory: true)
        let lib = gameDir.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so")
        try FileManager.default.createDirectory(
            at: lib.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: lib.path, contents: Data([0x1]))

        let install = InstalledMinecraft(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 1,
                abi: .arm64v8a
            ),
            originalVersionName: "1.26.51.1",
            relativeGameDirectory: gameDir.path,
            integrity: .verified,
            providerID: ProviderID(rawValue: "harbor-install"),
            packageReceipts: [lib.path]
        )
        try await services.metadata.saveInstallations([install])

        let app = AppState(services: services)
        await app.reload()
        #expect(app.hasVerifiedGame)
        #expect(app.nextStep == 3)

        try FileManager.default.removeItem(at: gameDir)
        await app.reload()
        #expect(!app.hasVerifiedGame, "game files deleted on disk — install step must come back")
    }

    /// The startup bootstrap finishes after the UI's first reload (it may download
    /// the runtime for ~40 s). When it completes, the UI must re-read metadata —
    /// otherwise the Home screen randomly stays on the "Install" step.
    @Test func bootstrapFinishedNotificationTriggersReload() async throws {
        let services = try makeServices()
        let gameDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-game-\(UUID().uuidString)", isDirectory: true)
        let lib = gameDir.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so")
        try FileManager.default.createDirectory(
            at: lib.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: lib.path, contents: Data([0x1]))
        let install = InstalledMinecraft(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 1,
                abi: .arm64v8a
            ),
            originalVersionName: "1.26.51.1",
            relativeGameDirectory: gameDir.path,
            integrity: .verified,
            providerID: ProviderID(rawValue: "harbor-install"),
            packageReceipts: [lib.path]
        )

        let app = AppState(services: services)
        await app.reload() // first (pre-bootstrap) reload: no installations yet
        #expect(!app.hasVerifiedGame)

        // Bootstrap writes the installation, then signals completion.
        try await services.metadata.saveInstallations([install])
        NotificationCenter.default.post(name: .harborBootstrapFinished, object: nil)

        // reload runs asynchronously on MainActor — yield until it lands.
        for _ in 0..<100 where !app.hasVerifiedGame {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(app.hasVerifiedGame, "metadata appeared while app ran — UI must reflect it without user action")
    }
}
