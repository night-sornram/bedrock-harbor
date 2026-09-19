import Foundation
import Testing
@testable import HarborFeatures
import HarborApplication
import HarborCompatibility
import HarborDomain
import HarborGooglePlay
import HarborPlatform
import AppKit
import SwiftUI

@MainActor
@Suite("AppState install gate", .serialized)
struct AppStateInstallGateTests {
    private func makeServices() throws -> HarborServiceBundle {
        PlayStoreIsolation.activate()
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
        resetPlayState()
        defer { resetPlayState() }
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
        #expect(!app.googlePlayStepIsComplete)
        #expect(app.googlePlayStepIsOptional)

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

    /// The Play store is process-global; tests run it against the shared
    /// ISOLATED temp stores (PlayStoreIsolation), so resetting clears only
    /// those — never the real user's ~/Library or UserDefaults.standard.
    /// Credential-asserting tests serialize (one test, sequential phases)
    /// because the temp store is shared per-process.
    private func resetPlayState() {
        let d = PlayStoreIsolation.defaults
        d.removeObject(forKey: "com.bedrockharbor.play.oauth")
        d.removeObject(forKey: "com.bedrockharbor.play.cookies")
        d.removeObject(forKey: "com.bedrockharbor.play.email")
        d.removeObject(forKey: "com.bedrockharbor.play.accountEmail")
        try? FileManager.default.removeItem(at: GPlayDLClient.workDir)
        let support = PlayStoreIsolation.home
            .appendingPathComponent("Library/Application Support/BedrockHarbor", isDirectory: true)
        try? FileManager.default.removeItem(at: support.appendingPathComponent("play-session.json"))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("play-oauth.token"))
        // Also drop the wipe-surviving backup so "signed out" phases stay
        // deterministic regardless of test order within the serialized suite.
        try? FileManager.default.removeItem(
            at: PlayStoreIsolation.home.appendingPathComponent(".bedrockharbor/credentials.json"))
    }

    @Test func savedCredentialsDoNotProveGoogleSignIn() async throws {
        let services = try makeServices()
        resetPlayState()
        defer { resetPlayState() }
        PlayCredentialBackup.save(master: "expired-test-master", email: "saved@example.com")
        let app = AppState(services: services)
        await app.reload()
        #expect(!app.isPlaySignedIn, "A saved credential must be validated before Accounts claims signed in")
    }

    @Test func otherProviderAccountDoesNotSignInGooglePlay() async throws {
        let services = try makeServices()
        resetPlayState()
        defer { resetPlayState() }
        try await services.metadata.saveAccounts([
            AccountRecord(providerID: ProviderID(rawValue: "other-provider"),
                          accountLabel: "other@example.com", sessionState: .ready,
                          keychainReference: "test")
        ])
        let app = AppState(services: services)
        await app.reload()
        #expect(!app.isPlaySignedIn)
        #expect(app.playAccountLabel.isEmpty)
    }

    @Test func storedBrowserSessionNeedsValidation() async throws {
        let services = try makeServices()
        resetPlayState()
        defer { resetPlayState() }
        let token = "oauth2_4/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBB"
        HarborPlayTokenBridge.saveOAuthToken(token)
        PlaySessionStore.save(cookies: ["oauth_token": token, "SID": "s"], email: "saved@example.com")
        let app = AppState(services: services)
        await app.reload()
        let signedIn = app.isPlaySignedIn
        #expect(!signedIn)
        #expect(HarborPlayTokenBridge.loadOAuthToken() == token,
                "An unverified/offline session must not be destroyed on reload")
    }

    @Test func signOutClearsEveryHarborGoogleStoreAndKeepsOtherAccounts() async throws {
        let services = try makeServices()
        resetPlayState()
        defer { resetPlayState() }
        let token = "oauth2_4/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBB"
        HarborPlayTokenBridge.saveOAuthToken(token)
        HarborPlayTokenBridge.saveAccountEmail("old@example.com")
        PlaySessionStore.save(cookies: ["oauth_token": token], email: "old@example.com")
        PlayCredentialBackup.save(oauth: token, master: "test-master", email: "old@example.com")
        let fm = FileManager.default
        try fm.createDirectory(at: GPlayDLClient.workDir, withIntermediateDirectories: true)
        for name in ["playdl.conf", "token_cache.conf", "device.conf.state"] {
            try "user_token = test-master\n".write(to: GPlayDLClient.workDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let other = AccountRecord(providerID: ProviderID(rawValue: "other-provider"),
                                  accountLabel: "other@example.com", sessionState: .ready, keychainReference: "other")
        try await services.metadata.saveAccounts([
            other, AccountRecord(providerID: .googlePlay, accountLabel: "old@example.com", sessionState: .ready, keychainReference: "google")
        ])
        var clearedBrowser = false
        let backend = LivePlaySessionBackend(metadata: services.metadata, clearBrowserCookies: { clearedBrowser = true })
        try await backend.clear()
        #expect(clearedBrowser)
        #expect(!backend.hasSavedCredentials())
        #expect(HarborPlayTokenBridge.loadOAuthToken() == nil)
        #expect(HarborPlayTokenBridge.loadAccountEmail() == nil)
        #expect(PlaySessionStore.load().cookies.isEmpty)
        #expect(PlaySessionStore.load().accountEmail == nil)
        #expect(PlayCredentialBackup.load().master == nil)
        #expect(PlayCredentialBackup.load().oauth == nil)
        #expect(try await services.metadata.loadAccounts() == [other])
        for name in ["playdl.conf", "token_cache.conf", "device.conf.state"] {
            #expect(!fm.fileExists(atPath: GPlayDLClient.workDir.appendingPathComponent(name).path))
        }
        let restarted = AppState(services: services)
        await restarted.reload()
        #expect(restarted.playSession.status == .signedOut)
        #expect(restarted.playAccountLabel.isEmpty)
    }

    @Test func authCheckUsesPrivateFilesAndCommitsOnlyVerifiedSession() async throws {
        let services = try makeServices()
        resetPlayState()
        defer { resetPlayState() }
        HarborPlayTokenBridge.saveOAuthToken("oauth2_4/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBB")
        let backend = LivePlaySessionBackend(
            metadata: services.metadata, clearBrowserCookies: {},
            binary: { URL(fileURLWithPath: "/test/gplayver") },
            runCheck: { _, args, directory in
                #expect(args.contains("--auth-check"))
                #expect(args.contains("--access-token-file"))
                #expect(!args.contains { $0.contains("oauth2_") })
                #expect(!args.contains("--accept-tos"))
                let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("access-token").path)
                #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                try "user_email = verified@example.com\nuser_token = verified-master\n".write(
                    to: directory.appendingPathComponent("playdl.conf"), atomically: true, encoding: .utf8)
                return SubprocessResult(exitCode: 0, stdout: "authentication verified\n", stderr: "", timedOut: false, truncated: false)
            }
        )
        let session = PlaySessionCoordinator(backend: backend)
        session.restoreIfNeeded()
        await session.waitForValidation()
        #expect(session.status == .signedIn(email: "verified@example.com", restored: true))
        #expect(FileManager.default.fileExists(atPath: GPlayDLClient.workDir.appendingPathComponent("playdl.conf").path))
    }

    @Test func failedAuthCheckDoesNotCommitStagedCredentialsOrEraseSavedToken() async throws {
        let services = try makeServices()
        resetPlayState()
        defer { resetPlayState() }
        let token = "oauth2_4/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBB"
        HarborPlayTokenBridge.saveOAuthToken(token)
        for code: Int32 in [2, 3] {
            let backend = LivePlaySessionBackend(
                metadata: services.metadata, clearBrowserCookies: {},
                binary: { URL(fileURLWithPath: "/test/gplayver") },
                runCheck: { _, _, directory in
                    try "user_email = partial@example.com\nuser_token = partial-token\n".write(
                        to: directory.appendingPathComponent("playdl.conf"), atomically: true, encoding: .utf8)
                    return SubprocessResult(exitCode: code, stdout: "", stderr: "", timedOut: false, truncated: false)
                }
            )
            let session = PlaySessionCoordinator(backend: backend)
            session.restoreIfNeeded()
            await session.waitForValidation()
            #expect(!session.status.isSignedIn)
            #expect((session.status == .expired) == (code == 3))
            #expect(HarborPlayTokenBridge.loadOAuthToken() == token)
            #expect(!FileManager.default.fileExists(atPath: GPlayDLClient.workDir.appendingPathComponent("playdl.conf").path))
        }
    }

    @Test func savingAnonymousCookiesClearsRememberedEmail() throws {
        _ = try makeServices()
        resetPlayState()
        defer { resetPlayState() }
        PlaySessionStore.save(cookies: ["SID": "test"], email: "stale@example.com")
        PlaySessionStore.save(cookies: [:], email: nil)
        #expect(PlaySessionStore.load().accountEmail == nil)
    }

    @Test func signedOutAccountsAndLocalPlayRenderInBothAppearances() async throws {
        let services = try makeServices()
        resetPlayState()
        defer { resetPlayState() }
        let app = AppState(services: services)
        await app.reload()
        app.hasVerifiedGame = true
        for scheme in [ColorScheme.light, .dark] {
            let appearance = scheme == .light ? "light" : "dark"
            let screens: [(String, AnyView)] = [
                ("accounts", AnyView(AccountsView(app: app, onRecovery: { _ in }))),
                ("play", AnyView(PlayView(app: app, onRecovery: { _ in })))
            ]
            for (name, view) in screens {
                let renderer = ImageRenderer(content: view
                    .frame(width: 700, height: 550)
                    .background(scheme == .light ? Color.white : Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme))
                let image = try #require(renderer.cgImage)
                #expect(image.width == 700 && image.height == 550)
                if let directory = ProcessInfo.processInfo.environment["HARBOR_UI_SNAPSHOTS"] {
                    let rep = NSBitmapImageRep(cgImage: image)
                    let data = try #require(rep.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(appearance).png"))
                }
            }
        }
    }

    /// Credentials must survive Application Support wipes — they live in a
    /// chmod-600 dotfile in the user's home.
    @Test func playCredentialBackupSurvivesOutsideAppSupport() {
        PlayStoreIsolation.activate()
        let fm = FileManager.default
        // Isolated backup file (inside the throwaway PlayStoreIsolation home)
        // — start clean so the round-trip below is deterministic.
        let url = PlayStoreIsolation.home.appendingPathComponent(".bedrockharbor/credentials.json")
        try? fm.removeItem(at: url)
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
