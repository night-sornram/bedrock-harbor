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

    /// A profile's selectedInstallationID / pinnedRuntimeReleaseID must drive the
    /// snapshot's gameInstallation / runtime picks — not just "first verified".
    @Test func gameInstallationAndRuntimeHonorProfileSelection() async throws {
        let services = try makeServices()
        let fm = FileManager.default

        func makeInstall(_ version: String) throws -> InstalledMinecraft {
            let gameDir = fm.temporaryDirectory
                .appendingPathComponent("bh-game-\(UUID().uuidString)", isDirectory: true)
            let lib = gameDir.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so")
            try fm.createDirectory(at: lib.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: lib.path, contents: Data([0x1]))
            return InstalledMinecraft(
                buildID: MinecraftBuildID(
                    packageIdentifier: "com.mojang.minecraftpe",
                    versionCode: 1,
                    abi: .arm64v8a
                ),
                originalVersionName: version,
                relativeGameDirectory: gameDir.path,
                integrity: .verified,
                providerID: ProviderID(rawValue: "harbor-install"),
                packageReceipts: [lib.path]
            )
        }

        // "Newer" first in the array so first-verified fallback would pick it.
        let newer = try makeInstall("1.26.51.1")
        let older = try makeInstall("1.20.1.01")
        try await services.metadata.saveInstallations([newer, older])

        let runtimes = [
            RuntimeInstallation(releaseID: "rel-new", relativeInstallPath: "/r/new", artifactSHA256: "a"),
            RuntimeInstallation(releaseID: "rel-old", relativeInstallPath: "/r/old", artifactSHA256: "b"),
        ]
        try await services.metadata.saveRuntimeInstallations(runtimes)

        let profile = Profile(name: "Default", selectedInstallationID: older.id, pinnedRuntimeReleaseID: "rel-old")
        try await services.metadata.saveProfiles([profile])

        let app = AppState(services: services)
        await app.reload()
        #expect(app.selectedProfileID == profile.id)
        #expect(app.gameInstallation?.originalVersionName == "1.20.1.01",
                "profile selects the older install — gameInstallation must honor it")
        #expect(app.runtime?.releaseID == "rel-old",
                "profile pins the older runtime — runtime must honor it")
    }

    /// hasVerifiedGame is a stored snapshot refreshed by reload(), not a live
    /// stat per read: deleting the receipt after reload must not change the
    /// stored value until the next reload observes it.
    @Test func hasVerifiedGameIsStoredSnapshotNotLiveStat() async throws {
        let services = try makeServices()
        let fm = FileManager.default
        let gameDir = fm.temporaryDirectory
            .appendingPathComponent("bh-game-\(UUID().uuidString)", isDirectory: true)
        let lib = gameDir.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so")
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

        // Phase 1: receipt missing → stored value false after reload.
        let app = AppState(services: services)
        await app.reload()
        #expect(!app.hasVerifiedGame, "receipt file missing — must read as not installed")

        // Phase 2: receipt appears → true after reload; deleting it afterwards
        // must NOT change the stored value until the next reload.
        try fm.createDirectory(at: lib.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: lib.path, contents: Data([0x1]))
        await app.reload()
        #expect(app.hasVerifiedGame)

        try fm.removeItem(at: gameDir)
        #expect(app.hasVerifiedGame, "snapshot: no re-stat between reads — value changes only on reload")

        await app.reload()
        #expect(!app.hasVerifiedGame, "next reload observes the missing receipt")
    }

    /// Startup bootstrap must not scan Downloads: a package sitting in
    /// (a temp) Downloads is invisible to `acquire(scope: .startup)` with empty
    /// metadata, while the explicit full scan (Rescan packages) imports it.
    @Test func startupScopeSkipsDownloadsFullScopeImports() async throws {
        let services = try makeServices()
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("bh-home-\(UUID().uuidString)", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads/1.26.51.1", isDirectory: true)
        let lib = downloads.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so")
        try fm.createDirectory(at: lib.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: lib.path, contents: Data([0x1]))

        // Startup scope: empty metadata → Harbor Installations root (empty) only.
        let startup = await GamePackageAcquirer.acquire(services: services, scope: .startup, home: home)
        #expect(startup.installation == nil, "startup scope must not discover the Downloads package")
        #expect(!startup.didImport)
        #expect(try await services.metadata.loadInstallations().isEmpty,
                "startup scope must not import anything")

        // Full scope: Downloads is scanned and the package is imported.
        let full = await GamePackageAcquirer.acquire(services: services, scope: .full, home: home)
        #expect(full.installation?.originalVersionName == "1.26.51.1")
        #expect(full.didImport)
        let recorded = try await services.metadata.loadInstallations()
        #expect(recorded.contains { $0.originalVersionName == "1.26.51.1" })
        #expect(recorded.allSatisfy { $0.relativeGameDirectory.hasPrefix(home.path) },
                "import must land inside the (temp) Harbor Installations root")
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

    /// Credentials must survive Application Support wipes — they live in a
    /// chmod-600 dotfile in the user's home.
    @Test func playCredentialBackupSurvivesOutsideAppSupport() {
        let fm = FileManager.default
        let url = fm.homeDirectoryForCurrentUser.appendingPathComponent(".bedrockharbor/credentials.json")
        defer { try? fm.removeItem(at: url) }

        PlayCredentialBackup.save(oauth: "oauth2_4/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", email: "a@gmail.com")
        var payload = PlayCredentialBackup.load()
        #expect(payload.oauth?.hasPrefix("oauth2_4/") == true)
        #expect(payload.email == "a@gmail.com")

        PlayCredentialBackup.save(master: "aas_et/MASTER")
        payload = PlayCredentialBackup.load()
        #expect(payload.master == "aas_et/MASTER", "master token added without dropping the oauth token")

        PlayCredentialBackup.clearMaster()
        payload = PlayCredentialBackup.load()
        #expect(payload.master == nil && payload.oauth != nil, "clearMaster drops only the master token")
    }

    /// CLI auth priority: existing playdl.conf → backup master token →
    /// sign-in access token → none (needs sign-in).
    @Test func gplayAuthArgsPreferSavedConfThenMasterThenOauth() {
        let viaConf = GPlayDLClient.authArgs(hasSavedConf: true, backupMaster: "m", backupEmail: "e@x.com", oauth: "o", email: "e@x.com")
        #expect(viaConf.args == [] && !viaConf.usedBackupMaster)

        let viaMaster = GPlayDLClient.authArgs(hasSavedConf: false, backupMaster: "m", backupEmail: "e@x.com", oauth: "o", email: "e@x.com")
        #expect(viaMaster.args == ["--token", "m", "--email", "e@x.com", "--save-auth"] && viaMaster.usedBackupMaster)

        let viaOauth = GPlayDLClient.authArgs(hasSavedConf: false, backupMaster: nil, backupEmail: nil, oauth: "o", email: nil)
        #expect(viaOauth.args == ["--access-token", "o", "--email", "", "--save-auth"])

        let none = GPlayDLClient.authArgs(hasSavedConf: false, backupMaster: nil, backupEmail: nil, oauth: nil, email: nil)
        #expect(none.args == nil)
    }

    @Test func gplayProgressParsing() {
        let full = GPlayDLClient.parseProgress("Downloaded 45% [400/886 MiB]")
        #expect(full?.percent ?? 0 == 0.45)
        #expect(full?.detail == "400/886 MiB")

        let nearDone = GPlayDLClient.parseProgress("Downloaded 100% [886/886 MiB]")
        #expect(nearDone?.percent ?? 0 == 1.0)

        #expect(GPlayDLClient.parseProgress("Google Play: retrying version check…") == nil)
    }
}
