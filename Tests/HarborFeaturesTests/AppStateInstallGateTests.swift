import Foundation
import Testing
@testable import HarborFeatures
import HarborApplication
import HarborCompatibility
import HarborDomain
import HarborGooglePlay
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

    /// The Play store is process-global (UserDefaults + real-home files), so
    /// parallel tests would race on it — one test, sequential phases.
    private func resetPlayState() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "com.bedrockharbor.play.oauth")
        d.removeObject(forKey: "com.bedrockharbor.play.cookies")
        d.removeObject(forKey: "com.bedrockharbor.play.email")
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BedrockHarbor", isDirectory: true)
        try? FileManager.default.removeItem(at: support.appendingPathComponent("play-session.json"))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("play-oauth.token"))
    }

    /// A token string saved over an anonymous cookie bag is a failed-login
    /// leftover (the loop bug): reload must self-heal to signed-out, not claim
    /// "Google Play ready" for a session that never signed in. A completed
    /// sign-in (oauth_token cookie in the bag) must survive the same reload.
    @Test func playSessionSelfHealsFromAnonymousLeftover() async throws {
        resetPlayState()
        defer { resetPlayState() }

        // Phase 1: anonymous leftover → signed out + cleared.
        let stale = try makeServices()
        HarborPlayTokenBridge.saveOAuthToken("oauth2_4/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBB")
        PlaySessionStore.save(cookies: ["NID": "n", "OTZ": "o"], email: "a@gmail.com")
        try await stale.metadata.saveAccounts([
            AccountRecord(
                providerID: .googlePlay,
                accountLabel: "a@gmail.com",
                sessionState: .ready,
                keychainReference: "test"
            )
        ])
        let staleApp = AppState(services: stale)
        await staleApp.reload()
        #expect(!staleApp.isPlaySignedIn, "anonymous cookie bag must not count as signed in")
        #expect(HarborPlayTokenBridge.loadOAuthToken() == nil, "leftover token must be cleared")
        #expect(!staleApp.accounts.contains { $0.providerID == .googlePlay })

        // Phase 2: completed sign-in → kept.
        let live = try makeServices()
        let token = "oauth2_4/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBB"
        HarborPlayTokenBridge.saveOAuthToken(token)
        PlaySessionStore.save(cookies: ["oauth_token": token, "SID": "s"], email: "a@gmail.com")
        let liveApp = AppState(services: live)
        await liveApp.reload()
        #expect(liveApp.isPlaySignedIn, "oauth_token cookie in the bag is a real completed sign-in")
    }
}
