import AppKit
import Foundation
import HarborApplication
import HarborDomain
import HarborGooglePlay
import HarborPlatform
import HarborRuntime
import SwiftUI

// MARK: - Shared

public struct StatusPill: View {
    public enum Tone { case neutral, ok, warn, bad }
    public let text: String
    public let tone: Tone
    public init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }
    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(Capsule())
    }
    private var bg: Color {
        switch tone {
        case .neutral: return Color.secondary.opacity(0.15)
        case .ok: return Color.green.opacity(0.2)
        case .warn: return Color.orange.opacity(0.22)
        case .bad: return Color.red.opacity(0.2)
        }
    }
    private var fg: Color {
        switch tone {
        case .neutral: return .secondary
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }
}

public struct StepRow: View {
    public let n: Int
    public let title: String
    public let subtitle: String
    public let done: Bool
    public let active: Bool
    public init(n: Int, title: String, subtitle: String, done: Bool, active: Bool) {
        self.n = n
        self.title = title
        self.subtitle = subtitle
        self.done = done
        self.active = active
    }
    public var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : (active ? Color.accentColor : Color.secondary.opacity(0.2)))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.caption.bold())
                        .foregroundStyle(active ? .white : .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - State

/// Posted once the startup bootstrap (runtime self-heal, metadata repair, package
/// acquisition) has finished — it can run for ~40 s after a data wipe, well past
/// the UI's first metadata read. AppState reloads on it so the Home screen cannot
/// stay stuck on the "Install" step for an already-installed game.
extension Notification.Name {
    public static let harborBootstrapFinished = Notification.Name("com.bedrockharbor.bootstrap.finished")
}

@MainActor
@Observable
public final class AppState {
    public var profiles: [Profile] = []
    public var installations: [InstalledMinecraft] = []
    public var runtimes: [RuntimeInstallation] = []
    public var selectedProfileID: UUID?
    public var status: String = ""
    public var isGameRunning = false
    public var isInstalling = false
    public var signInBusy = false
    /// Active download progress (0...1); nil when nothing measurable is downloading.
    public var downloadProgress: Double?
    public var downloadDetail = ""
    public var downloadLabel = ""
    public var playAccountLabel = ""
    public var accounts: [AccountRecord] = []
    public var needsOnboarding = true
    public var doctorLines: [String] = []

    // Derived snapshot: these used to be computed properties that hit the
    // filesystem, the Keychain/token bridge, and UserDefaults on every SwiftUI
    // render. They are now stored values refreshed by `refreshDerivedState()`
    // from `reload()` and after every mutating action — views only ever read
    // the stored fields.
    public var gameInstallation: InstalledMinecraft?
    public var runtime: RuntimeInstallation?
    public var hasVerifiedGame = false
    public var isPlaySignedIn = false

    public let services: HarborServiceBundle
    private var sessionCoordinator: GameSessionCoordinator?
    private let bootstrapBox = ObserverBox()

    private static let localAPKKey = "com.bedrockharbor.localapk.mode"
    private static let onboardKey = "com.bedrockharbor.onboarding.completed"
    /// Process name of the runtime's Microsoft sign-in helper (Qt webview).
    private static let microsoftHelperProcessName = "mcpelauncher-webview"
    /// The helper spawns only when the player opens Microsoft sign-in in-game —
    /// often minutes into a session — so its spawn watcher gets a longer bound
    /// than the default. Marks after the timing session ends are ignored.
    private static let microsoftHelperWatchTimeout: TimeInterval = 600

    public init(services: HarborServiceBundle) {
        self.services = services
        self.sessionCoordinator = GameSessionCoordinator(services: services)
        self.needsOnboarding = !UserDefaults.standard.bool(forKey: Self.localAPKKey)
        bootstrapBox.token = NotificationCenter.default.addObserver(
            forName: .harborBootstrapFinished,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.reload() }
        }
    }

    deinit {
        if let token = bootstrapBox.token { NotificationCenter.default.removeObserver(token) }
    }

    public var selectedProfile: Profile? {
        profiles.first { $0.id == selectedProfileID }
            ?? profiles.first { $0.selectedInstallationID != nil }
            ?? profiles.first
    }

    /// Recomputes the derived snapshot (gameInstallation, runtime,
    /// hasVerifiedGame, isPlaySignedIn) from the freshly loaded arrays and the
    /// credential stores. Runs inside `reload()` and after mutating actions —
    /// never from a SwiftUI `body`.
    func refreshDerivedState() {
        let profile = selectedProfile

        // gameInstallation honors the profile: its selected install first,
        // then first verified, then first.
        if let wanted = profile?.selectedInstallationID,
           let match = installations.first(where: { $0.id == wanted }) {
            gameInstallation = match
        } else {
            gameInstallation = installations.first { $0.integrity == .verified }
                ?? installations.first
        }

        // runtime honors the profile: its pinned release first, then first.
        if let pinned = profile?.pinnedRuntimeReleaseID,
           let match = runtimes.first(where: { $0.releaseID == pinned }) {
            runtime = match
        } else {
            runtime = runtimes.first
        }

        // Disk-verified on purpose: the first metadata read races the startup
        // bootstrap (and a lost concurrent write can drop the record), and
        // trusting metadata alone randomly leaves the UI on the "Install
        // Minecraft" step for an installed game.
        if let install = gameInstallation, install.integrity == .verified {
            let receipt = install.packageReceipts.first
                ?? URL(fileURLWithPath: install.relativeGameDirectory, isDirectory: true)
                    .appendingPathComponent("lib/arm64-v8a/libminecraftpe.so").path
            hasVerifiedGame = FileManager.default.fileExists(atPath: receipt)
        } else {
            hasVerifiedGame = false
        }

        isPlaySignedIn = computePlaySignedIn()
    }

    /// Credential snapshot behind `isPlaySignedIn`. Same semantics as the old
    /// per-render computed property (including the wipe-surviving backup),
    /// computed once per reload/action instead of per SwiftUI render.
    private func computePlaySignedIn() -> Bool {
        if HarborPlayTokenBridge.loadOAuthToken() != nil { return true }
        if PlaySessionStore.load().cookies["oauth_token"] != nil { return true }
        // Wipe-surviving credential backup (see PlayCredentialBackup) — after a
        // data wipe the app is still truthfully signed in for downloads.
        let backup = PlayCredentialBackup.load()
        if backup.master != nil || backup.oauth != nil { return true }
        return accounts.contains { $0.sessionState == .ready && $0.accountLabel.contains("@") }
    }

    public var nextStep: Int {
        if hasVerifiedGame { return 3 }
        if isPlaySignedIn || usedLocalAPK { return 2 }
        return 1
    }

    public var usedLocalAPK: Bool {
        get { UserDefaults.standard.bool(forKey: Self.localAPKKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.localAPKKey) }
    }

    public func refreshGate() {
        // A verified local game package is enough to play — Google Play sign-in is only
        // needed for store features, never for launching an installed package.
        if isPlaySignedIn || usedLocalAPK || hasVerifiedGame {
            needsOnboarding = false
        } else {
            needsOnboarding = true
        }
    }

    public func reload() async {
        profiles = (try? await services.metadata.loadProfiles()) ?? []
        installations = (try? await services.metadata.loadInstallations()) ?? []
        runtimes = (try? await services.metadata.loadRuntimeInstallations()) ?? []
        accounts = (try? await services.metadata.loadAccounts()) ?? []
        await reconcilePersistedPlaySession()
        if let ready = accounts.first(where: { $0.sessionState == .ready }) {
            playAccountLabel = ready.accountLabel
        }
        if selectedProfileID == nil { selectedProfileID = profiles.first?.id }
        refreshDerivedState()
        refreshGate()
        status = status.isEmpty ? readySummary() : status
    }

    /// A stored Play token sitting on an anonymous cookie bag (no oauth_token
    /// cookie, no Google session cookies) cannot install anything — it is a
    /// leftover from a login that faked completion. Clear it instead of
    /// claiming "Google Play ready" for a session that never really signed in.
    private func reconcilePersistedPlaySession() async {
        let session = PlaySessionStore.load()
        let hasSessionCookies = [
            "SID", "SAPISID", "HSID", "LSID", "SIDCC",
            "__Secure-3PSID", "__Secure-3PAPISID",
        ].contains { session.cookies[$0] != nil }
        let hasPlayAccount = accounts.contains { $0.providerID == .googlePlay }
        guard session.cookies["oauth_token"] == nil,
              !hasSessionCookies,
              HarborPlayTokenBridge.loadOAuthToken() != nil || hasPlayAccount
        else { return }
        HarborPlayTokenBridge.clearOAuthToken()
        PlaySessionStore.save(cookies: [:], email: nil)
        accounts.removeAll { $0.providerID == .googlePlay }
        try? await services.metadata.saveAccounts(accounts)
        playAccountLabel = ""
    }

    private func readySummary() -> String {
        if !isPlaySignedIn && !usedLocalAPK { return "Step 1 — Sign in with Google Play" }
        if !hasVerifiedGame { return "Step 2 — Install Minecraft" }
        return "Step 3 — Launch"
    }

    public func completeOnboardingFromLogin() {
        needsOnboarding = false
        UserDefaults.standard.set(true, forKey: Self.onboardKey)
        refreshGate()
    }

    public func useLocalAPK() {
        usedLocalAPK = true
        needsOnboarding = false
        status = "Local package mode — Install from APK / folder… or Rescan packages"
        refreshDerivedState()
        refreshGate()
    }

    public func rescanPackages() async {
        isInstalling = true
        defer { isInstalling = false }
        status = "Scanning for Minecraft packages…"
        let result = await GamePackageAcquirer.acquire(services: services)
        await reload()
        if let install = result.installation {
            status = "Package ready: \(install.originalVersionName) — Launch"
        } else {
            status = "No Minecraft package found. Use Install Minecraft (downloads from Google Play), or Install from APK / folder…"
        }
    }

    /// Onboarding leads with "Sign in with Google Play", but a local package
    /// (external launcher dirs, a prior install) makes login unnecessary —
    /// scan once on entry so the screen reflects the real state instead of
    /// demanding a login that is not needed to play.
    public func autoDetectLocalPackage() async {
        guard !hasVerifiedGame, !isInstalling else { return }
        let result = await GamePackageAcquirer.acquire(services: services)
        await reload()
        if let install = result.installation {
            status = "Minecraft \(install.originalVersionName) found on this Mac — no Google sign-in needed"
        }
    }

    public func resetSetup() {
        usedLocalAPK = false
        needsOnboarding = true
        UserDefaults.standard.set(false, forKey: Self.onboardKey)
        refreshGate()
    }

    // MARK: Actions

    /// The Minecraft Bedrock Launcher runtime ships mcpelauncher-extract + mcpelauncher-client.
    /// When it is missing (fresh Mac, wiped data) Harbor installs it automatically —
    /// no manual script step.
    public func ensureLauncherRuntimeInstalled() async -> Bool {
        if HarborRuntimeInstaller.runtimePresent() {
            // Runtime is on disk — but if metadata lost the record (startup race,
            // wiped metadata), repair it so Launch and the step list don't act as
            // if an install is still pending.
            if runtime == nil, let bundle = LocalRuntimeDiscovery().discoverDefault() {
                var runtimes = (try? await services.metadata.loadRuntimeInstallations()) ?? []
                if !runtimes.contains(where: { $0.releaseID == bundle.runtimeInstallation.releaseID }) {
                    runtimes.append(bundle.runtimeInstallation)
                    try? await services.metadata.saveRuntimeInstallations(runtimes)
                }
                await reload()
            }
            return true
        }
        status = "Installing Minecraft Bedrock Launcher…"
        defer { downloadProgress = nil }
        downloadLabel = "Minecraft Bedrock Launcher"
        do {
            _ = try await HarborRuntimeInstaller.ensureInstalled(status: { text in
                Task { @MainActor in
                    self.status = text
                    if let pctToken = text.range(of: #"\d+%"#, options: .regularExpression),
                       let percent = Double(text[pctToken].dropLast()) {
                        self.downloadProgress = percent / 100
                        self.downloadDetail = ""
                    }
                }
            })
        } catch {
            status = "Minecraft Bedrock Launcher install failed: \(error.localizedDescription)"
            return false
        }
        // Persist the freshly installed runtime so Launch works in this same session.
        guard let bundle = LocalRuntimeDiscovery().discoverDefault() else {
            status = "Minecraft Bedrock Launcher installed but not detected — restart Harbor"
            return false
        }
        var runtimes = (try? await services.metadata.loadRuntimeInstallations()) ?? []
        if let i = runtimes.firstIndex(where: { $0.releaseID == bundle.runtimeInstallation.releaseID }) {
            runtimes[i] = bundle.runtimeInstallation
        } else {
            runtimes.append(bundle.runtimeInstallation)
        }
        try? await services.metadata.saveRuntimeInstallations(runtimes)
        await reload()
        status = "Minecraft Bedrock Launcher installed — continuing…"
        return true
    }

    /// Wait for sign-in sheet exactly once (observer + timeout must not both resume).
    private final class ResumeOnce: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func resume(_ cont: CheckedContinuation<Void, Never>) {
            lock.lock()
            let already = done
            done = true
            lock.unlock()
            if !already { cont.resume() }
        }
    }

    private final class ObserverBox: @unchecked Sendable {
        var token: NSObjectProtocol?
    }

    public func googleSignIn(fresh: Bool = false) async {
        signInBusy = true
        status = fresh ? "Opening Google sign-in (fresh Android setup)…" : "Opening Google sign-in…"
        GoogleSignInController.shared.present(freshLogin: fresh)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce()
            let observerBox = ObserverBox()
            let center = NotificationCenter.default
            observerBox.token = center.addObserver(forName: .bhGoogleSignInFinished, object: nil, queue: .main) { _ in
                if let token = observerBox.token { center.removeObserver(token) }
                once.resume(cont)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                if let token = observerBox.token { center.removeObserver(token) }
                once.resume(cont)
            }
        }

        let session = PlaySessionStore.load()
        let oauth = HarborPlayTokenBridge.loadOAuthToken() ?? session.cookies["oauth_token"]
        var email = GoogleSignInController.shared.signedInEmail
        if email == nil || !(email?.contains("@") ?? false) {
            email = HarborPlayTokenBridge.loadAccountEmail()
        }
        if email == nil || !(email?.contains("@") ?? false) {
            if session.accountEmail?.contains("@") == true { email = session.accountEmail }
            else if let e = session.cookies["Email"], e.contains("@") { email = e }
        }
        let userID = session.cookies["user_id"]

        if oauth != nil || (email?.contains("@") ?? false) {
            if let email, email.contains("@") {
                playAccountLabel = email
                HarborPlayTokenBridge.saveAccountEmail(email)
            } else if let userID {
                playAccountLabel = "Play user \(userID.prefix(8))…"
            } else {
                playAccountLabel = "Google Play"
            }
            let account = AccountRecord(
                providerID: .googlePlay,
                accountLabel: playAccountLabel,
                sessionState: .ready,
                keychainReference: "play-\(UUID().uuidString)"
            )
            accounts.removeAll { $0.providerID == .googlePlay }
            accounts.append(account)
            try? await services.metadata.saveAccounts(accounts)
            if oauth != nil {
                completeOnboardingFromLogin()
                status = "Play token ready (\(playAccountLabel)) — next: Install Minecraft"
            } else {
                status = "Signed in as \(playAccountLabel), but oauth_token missing — open Android setup once more"
                needsOnboarding = true
                refreshGate()
            }
        } else {
            status = "Google sign-in not finished — complete Android setup until status shows oauth_token"
        }
        signInBusy = false
        await reload()
    }

    public func installGame() async {
        // A second concurrent run would start a duplicate ~1 GB download.
        guard !isInstalling else { return }
        isInstalling = true
        defer {
            isInstalling = false
            downloadProgress = nil
        }

        // Prefer any package already on disk before Play network paths.
        let local = await GamePackageAcquirer.acquire(services: services)
        if let existing = local.installation, existing.integrity == .verified {
            await reload()
            status = "Minecraft \(existing.originalVersionName) ready — Launch"
            return
        }

        // APK extraction needs mcpelauncher-extract — install the launcher runtime first.
        guard await ensureLauncherRuntimeInstalled() else { return }

        status = "Checking Google Play session…"
        var auth = await PlaySessionStore.harvestFromWebKit(email: playAccountLabel.isEmpty ? nil : playAccountLabel)
        if auth.cookies.isEmpty {
            auth = PlaySessionStore.load()
        }

        var oauth = HarborPlayTokenBridge.loadOAuthToken()
        if oauth == nil, auth.cookies["oauth_token"] != nil {
            oauth = auth.cookies["oauth_token"]
            if let oauth { HarborPlayTokenBridge.saveOAuthToken(oauth) }
        }

        // Path A requires Android setup oauth_token — not only website cookies.
        if oauth == nil {
            status = "Need Play client token (oauth_token) — open Android Google setup once"
            needsOnboarding = true
            refreshGate()
            // Not fresh on purpose: wiping the WKWebView session on every retry
            // throws away the user's Google login and reads as bot-like churn.
            await googleSignIn()
            auth = await PlaySessionStore.harvestFromWebKit(email: playAccountLabel.isEmpty ? nil : playAccountLabel)
            if auth.cookies.isEmpty { auth = PlaySessionStore.load() }
            oauth = HarborPlayTokenBridge.loadOAuthToken()
            if oauth == nil { oauth = auth.cookies["oauth_token"] }
            if oauth == nil {
                status = "oauth_token not captured yet. In the Google window finish Android setup (I agree) until status shows oauth_token, then Install again."
                return
            }
        }

        if auth.cookies.isEmpty {
            auth = PlaySessionStore.load()
        }

        // Resolve email/user_id without bouncing to login when token already exists.
        var email = playAccountLabel.contains("@") ? playAccountLabel : nil
        if email == nil, auth.accountEmail?.contains("@") == true { email = auth.accountEmail }
        if email == nil, let e = auth.cookies["Email"], e.contains("@") { email = e }
        if email == nil, let e = HarborPlayTokenBridge.loadAccountEmail() { email = e }
        let userID = auth.cookies["user_id"] ?? email ?? "play-user"

        if email == nil || playAccountLabel == "Google Play account" || playAccountLabel.isEmpty {
            let listing = await PlayStoreInspector().inspect(auth: auth)
            if let e = listing.accountEmail { email = e; HarborPlayTokenBridge.saveAccountEmail(e) }
            status = "Play client token ready. \(listing.summary)"
        } else if let email {
            status = "Signed in as \(email) — installing with Harbor Play client…"
        } else {
            status = "Play client token ready — installing with Harbor Play client…"
        }
        if let email, email.contains("@") {
            playAccountLabel = email
        } else if playAccountLabel.isEmpty || playAccountLabel == "Google Play account" {
            playAccountLabel = "Play user \(userID.prefix(8))…"
        }

        // Community Google-Play-API client first: Google's delivery gateway
        // rejects Harbor's own client (HTTP 400) but accepts this one. First
        // run exchanges the sign-in access token for a master token that
        // gplaydl persists; later runs need no sign-in at all.
        downloadLabel = "Minecraft"
        if let gplay = await GPlayDLClient.download(
            oauth: oauth,
            email: email,
            status: { self.status = $0 },
            progress: { percent, detail in
                self.downloadProgress = percent
                self.downloadDetail = detail
            }
        ) {
            do {
                let dest = GamePackageAcquirer.harborInstallRoot()
                    .appendingPathComponent(gplay.versionName, isDirectory: true)
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                if let extractor = findExtractor() {
                    // Exit status unchecked on purpose: importIntoHarbor verifies
                    // libminecraftpe.so below, exactly like the old blocking run.
                    _ = try await HarborSubprocess.run(
                        executable: extractor,
                        arguments: gplay.files.map(\.path) + [dest.path],
                        timeout: 600
                    )
                    let install = try await GamePackageAcquirer.importIntoHarbor(from: dest, services: services)
                    try? FileManager.default.removeItem(at: gplay.stagingDir)
                    await reload()
                    status = "Installed via Google-Play-API client — \(install.originalVersionName)"
                    return
                } else if let first = gplay.files.first {
                    _ = try await GamePackageAcquirer.extractAPK(first, services: services)
                    try? FileManager.default.removeItem(at: gplay.stagingDir)
                    await reload()
                    status = "Installed via Google-Play-API client"
                    return
                }
            } catch {
                status = "Google-Play-API install failed: \(error.localizedDescription) — trying Harbor client…"
            }
        }

        let client = HarborPlayClient()

        var credential: HarborPlayClient.Credential?
        do {
            credential = try await client.authorize(
                accessToken: oauth,
                email: email,
                userID: userID,
                cookieSession: auth
            )
            status = "Play client authorized — downloading…"
        } catch let error as HarborError {
            switch error {
            case .reauthenticationRequired:
                // Only re-login when we truly have no Play token. "Sign in again" is not the default.
                if oauth == nil {
                    status = "No Play client token — opening Android Google setup once"
                    await googleSignIn()
                    auth = PlaySessionStore.load()
                    oauth = HarborPlayTokenBridge.loadOAuthToken() ?? auth.cookies["oauth_token"]
                    if let oauth {
                        credential = try? await client.authorize(
                            accessToken: oauth,
                            email: email ?? (auth.accountEmail?.contains("@") == true ? auth.accountEmail : nil),
                            userID: auth.cookies["user_id"] ?? userID,
                            cookieSession: auth
                        )
                    } else {
                        status = "oauth_token still missing. Settings → Sign in again (fresh), finish Android setup until status shows oauth_token."
                    }
                } else {
                    status = "Play token exists; Google still rejected auth. Do not sign in again — token exchange failed."
                }
            case .providerFailure(let reason):
                status = "\(reason) — if oauth_token is already captured, do not Sign in again; try Settings → fresh setup only when token is missing, or Install from APK."
            default:
                status = error.localizedDescription
            }
        } catch {
            status = error.localizedDescription
        }

        if let credential {
            do {
                let version = try await client.latestVersion(credential: credential)
                status = "Play version \(version.versionName ?? String(version.versionCode)) — downloading…"
                let staging = services.paths.stagingCache
                    .appendingPathComponent("harbor-play-\(UUID().uuidString)", isDirectory: true)
                let files = try await client.downloadDelivery(
                    versionCode: version.versionCode,
                    credential: credential,
                    outputDirectory: staging
                )
                status = "Downloaded \(files.count) APK file(s) — installing…"
                let versionName = version.versionName ?? "play-\(version.versionCode)"
                let dest = GamePackageAcquirer.harborInstallRoot().appendingPathComponent(versionName, isDirectory: true)
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                if let extractor = findExtractor() {
                    // Exit status unchecked on purpose: importIntoHarbor below
                    // verifies libminecraftpe.so, exactly like before.
                    _ = try await HarborSubprocess.run(
                        executable: extractor,
                        arguments: files.map(\.fileURL.path) + [dest.path],
                        timeout: 600
                    )
                } else {
                    _ = try await GamePackageAcquirer.extractAPK(files[0].fileURL, services: services)
                    await reload()
                    status = "Installed via Harbor Play client"
                    return
                }
                let install = try await GamePackageAcquirer.importIntoHarbor(from: dest, services: services)
                await reload()
                status = "Installed via Harbor Play client — \(install.originalVersionName)"
                return
            } catch {
                status = "Harbor Play download failed: \(error.localizedDescription)"
                return
            }
        }

        // Signed-in fallback: cookie-based Play probe (does not require another login).
        status = "Trying Play download with existing session…"
        do {
            let staging = services.paths.stagingCache
                .appendingPathComponent("play-web-\(UUID().uuidString)", isDirectory: true)
            let result = try await PlayDeliveryClient().downloadPackage(auth: auth, into: staging)
            status = "Play session download complete (\(result.fileCount)) — installing…"
            let apks = ((try? FileManager.default.contentsOfDirectory(at: result.packageDirectory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "apk" }
            if let first = apks.first {
                _ = try await GamePackageAcquirer.extractAPK(first, services: services)
                await reload()
                status = "Installed from Play session download"
            } else {
                status = Self.packageNeededMessage(details: "Play returned no APK files")
            }
        } catch {
            status = Self.packageNeededMessage(details: error.localizedDescription)
        }
        await reload()
    }

    /// Clear UX when Google will not hand APKs to Harbor.
    private static func packageNeededMessage(details: String) -> String {
        """
        Harbor could not download Minecraft from Google Play this time.\n\n\
        Things to check:\n\
        1) The signed-in Google account owns Minecraft on Play\n\
        2) Run setup again, then Install — a fresh Play token often fixes it\n\
        3) Home → Install from APK / folder… (owned base.apk or game folder with lib/arm64-v8a/libminecraftpe.so)\n\n\
        Play login can still be real. This is Google delivery policy, not a Harbor account bug.\n\n\
        Detail: \(details)
        """
    }

    public func openPlayStoreListing() {
        NSWorkspace.shared.open(PlayStoreInspector.detailsURL)
        status = "Opened Minecraft on Google Play — you can install to an Android device from there"
    }

    private func findExtractor() -> URL? {
        let runtimes = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BedrockHarbor/Runtimes", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: runtimes, includingPropertiesForKeys: nil) else { return nil }
        for entry in entries {
            let tool = entry.appendingPathComponent("MacOS/mcpelauncher-extract")
            if FileManager.default.isExecutableFile(atPath: tool.path) { return tool }
        }
        return nil
    }

    public func importAPK() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select Minecraft .apk or a folder with lib/arm64-v8a/libminecraftpe.so"
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else {
            status = "Install cancelled"
            return
        }
        let services = self.services
        Task {
            do {
                let install: InstalledMinecraft
                if url.pathExtension.lowercased() == "apk" {
                    guard await self.ensureLauncherRuntimeInstalled() else { return }
                    install = try await GamePackageAcquirer.extractAPK(url, services: services)
                } else {
                    install = try await GamePackageAcquirer.importIntoHarbor(from: url, services: services)
                }
                await reload()
                status = "Installed \(install.originalVersionName)"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    public func launchGame() async {
        if nextStep == 1 && !usedLocalAPK {
            status = "Step 1 required — Sign in with Google Play"
            return
        }
        if !hasVerifiedGame {
            await installGame()
            guard hasVerifiedGame else {
                status = "Cannot launch — Minecraft package missing"
                return
            }
        }
        if runtime == nil {
            // Last-resort self-heal (startup install may have failed while offline).
            guard await ensureLauncherRuntimeInstalled() else { return }
        }
        guard let profile = selectedProfile,
              let installation = gameInstallation,
              let runtime
        else {
            status = "Missing profile, game, or runtime"
            return
        }
        let coordinator = sessionCoordinator ?? GameSessionCoordinator(services: services)
        sessionCoordinator = coordinator
        do {
            let verified = try await GameSessionCoordinator.verifyInstallation(installation, services: services)
            guard verified.integrity == .verified else {
                status = "Game package not verified"
                return
            }
            let session = try await coordinator.launch(profile: profile, installation: verified, runtime: runtime)
            isGameRunning = true
            status = "Game running (pid \(session.processIdentifier.map(String.init) ?? "?"))"
            startLaunchWindowWatchers(session: session)
        } catch {
            isGameRunning = false
            let msg = error.localizedDescription
            if msg.lowercased().contains("pthread_sigmask")
                || msg.lowercased().contains("cannot locate symbol")
                || msg.lowercased().contains("failed to load minecraft")
                || msg.lowercased().contains("please reinstall or wait") {
                status = """
                Minecraft \(installation.originalVersionName) failed to start.\n\
                Harbor applies official mcpelauncher-updates patches on launch when available.\n\
                Check Settings → Doctor, or re-import an owned APK. Detail: \(msg)
                """
            } else {
                status = msg
            }
        }
    }

    public func stopGame() async {
        guard let coordinator = sessionCoordinator else {
            status = "Nothing to stop"
            return
        }
        try? await coordinator.requestStop()
        // No reconcileExited() here: the coordinator releases the lease itself
        // once the runtime confirms the process exited (terminal RuntimeEvent).
        isGameRunning = false
        status = "Stop requested"
    }

    /// Game-window and Microsoft-helper measurement (Task 1 pieces): one
    /// watcher for the launched pid (`gameWindowVisible`), one for the
    /// `mcpelauncher-webview` process (`microsoftHelperSpawned`), and once
    /// that helper spawns a pid-keyed window watcher
    /// (`microsoftWindowVisible`). All marks go into the supervisor's
    /// in-flight `launch` timing session — this measures Microsoft-window
    /// startup separately from the game window. Watchers self-cancel at their
    /// timeout, and once the session ends the recorder ignores further marks,
    /// so a late watcher can never corrupt the next session.
    private func startLaunchWindowWatchers(session: LaunchSession) {
        guard
            let supervisor = services.runtimeLauncher as? ProcessLaunchSupervisor,
            let pid = session.processIdentifier
        else { return }
        let recorder = supervisor.launchTiming
        WindowAppearanceWatcher.watch(ownerPID: pid, stage: .gameWindowVisible, recorder: recorder)
        WindowAppearanceWatcher.watchProcessSpawn(
            processName: Self.microsoftHelperProcessName,
            stage: .microsoftHelperSpawned,
            recorder: recorder,
            timeout: Self.microsoftHelperWatchTimeout
        ) { helperPID in
            WindowAppearanceWatcher.watch(
                ownerPID: helperPID,
                stage: .microsoftWindowVisible,
                recorder: recorder
            )
        }
    }

    public func runDoctor() async {
        let snap = (try? await DiagnosticsWorkflow(services: services).collect()) ?? DiagnosticsSnapshot()
        doctorLines = snap.findings.map { "\($0.severity.rawValue): \($0.title) — \($0.detail)" }
        status = "Doctor: \(snap.findings.count) checks"
    }

    public func deleteProfile(_ profile: Profile) async {
        if let workflow = ProfileWorkflow(services: services) as ProfileWorkflow? {
            try? await workflow.delete(id: profile.id)
        }
        await reload()
        status = "Deleted profile \(profile.name)"
    }
}

// MARK: - Onboarding (forced, simple)

public struct OnboardingView: View {
    public let app: AppState
    public init(app: AppState) { self.app = app }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HarborCover(height: 120)

            VStack(alignment: .leading, spacing: 14) {
                StepRow(
                    n: 1,
                    title: "Sign in with Google Play",
                    subtitle: app.hasVerifiedGame
                        ? "Optional — Minecraft is already on this Mac"
                        : "Needed only to download from Google Play",
                    done: app.isPlaySignedIn || app.hasVerifiedGame,
                    active: app.nextStep == 1 && !app.hasVerifiedGame
                )
                StepRow(
                    n: 2,
                    title: "Install Minecraft",
                    subtitle: "Harbor downloads or imports your game",
                    done: app.hasVerifiedGame,
                    active: app.nextStep == 2
                )
                StepRow(
                    n: 3,
                    title: "Launch",
                    subtitle: "Start the game",
                    done: app.isGameRunning,
                    active: app.nextStep == 3
                )
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if !app.isPlaySignedIn {
                Button {
                    Task { await app.googleSignIn() }
                } label: {
                    HStack {
                        if app.signInBusy { ProgressView() }
                        Image(systemName: "person.crop.circle")
                        Text("Sign in with Google Play")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.signInBusy)
            } else {
                Text("Play account ready: \(app.playAccountLabel.isEmpty ? "Google Play" : app.playAccountLabel)")
                    .foregroundStyle(.green)
                    .font(.headline)
            }

            Button("I have an APK — skip Play download") {
                app.useLocalAPK()
            }
            .buttonStyle(.link)
            .font(.caption)

            if let pct = app.downloadProgress {
                DownloadProgressCard(
                    label: app.downloadLabel.isEmpty ? "Minecraft" : app.downloadLabel,
                    progress: pct,
                    detail: app.downloadDetail
                )
            }

            if !app.status.isEmpty {
                Text(app.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await app.reload()
            await app.autoDetectLocalPackage()
        }
    }
}

// MARK: - Download progress

struct DownloadProgressCard: View {
    let label: String
    let progress: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Downloading \(label) — \(Int((progress * 100).rounded()))%")
                    .font(.callout.weight(.medium))
                Spacer()
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Home

public struct HomeView: View {
    public let app: AppState
    public init(app: AppState) { self.app = app }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HarborCover(height: 96)

                // Progress
                VStack(alignment: .leading, spacing: 12) {
                    StepRow(n: 1, title: "Google Play", subtitle: app.isPlaySignedIn ? app.playAccountLabel : "Not signed in", done: app.isPlaySignedIn, active: app.nextStep == 1)
                    StepRow(n: 2, title: "Minecraft", subtitle: app.hasVerifiedGame ? (app.gameInstallation?.originalVersionName ?? "") : "Not installed", done: app.hasVerifiedGame, active: app.nextStep == 2)
                    StepRow(n: 3, title: "Game", subtitle: app.isGameRunning ? "Running" : "Not running", done: app.isGameRunning, active: app.nextStep == 3)
                }
                .padding()
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Primary action only
                Group {
                    switch app.nextStep {
                    case 1:
                        Button {
                            Task { await app.googleSignIn() }
                        } label: {
                            Label("Sign in with Google Play", systemImage: "person.crop.circle")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.signInBusy)
                    case 2:
                        VStack(spacing: 10) {
                            Button {
                                Task { await app.installGame() }
                            } label: {
                                Label(
                                    app.isInstalling ? "Working…" : "Install / import Minecraft",
                                    systemImage: "icloud.and.arrow.down"
                                )
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(app.isInstalling)

                            HStack(spacing: 12) {
                                Button("Rescan packages") {
                                    Task { await app.rescanPackages() }
                                }
                                Button("Install from APK / folder…") { app.importAPK() }
                            }
                            .font(.caption)
                        }
                    default:
                        HStack(spacing: 12) {
                            Button {
                                Task { await app.launchGame() }
                            } label: {
                                Label("Launch", systemImage: "play.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            if app.isGameRunning {
                                Button("Stop") {
                                    Task { await app.stopGame() }
                                }
                            }
                        }
                    }
                }

                // Download progress
                if let pct = app.downloadProgress {
                    DownloadProgressCard(
                        label: app.downloadLabel.isEmpty ? "Minecraft" : app.downloadLabel,
                        progress: pct,
                        detail: app.downloadDetail
                    )
                }

                // Status
                if !app.status.isEmpty {
                    HStack {
                        StatusPill(app.status, tone: app.status.lowercased().contains("ready")
                                   || app.status.lowercased().contains("running")
                                   || app.status.lowercased().contains("signed")
                                   ? .ok : (app.status.lowercased().contains("cannot") || app.status.lowercased().contains("missing") ? .bad : .neutral))
                        Spacer()
                    }
                }

                // Compact details
                GroupBox("Details") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Profile", value: app.selectedProfile?.name ?? "—")
                        LabeledContent("Runtime", value: app.runtime.map { "\($0.releaseID) [\($0.health.rawValue)]" } ?? "—")
                        LabeledContent("Game", value: app.gameInstallation.map { "\($0.originalVersionName) [\($0.integrity.rawValue)]" } ?? "Not installed")
                    }
                    .padding(4)
                }

                // Secondary
                HStack(spacing: 16) {
                    Button("Open Minecraft on Play Store") { app.openPlayStoreListing() }
                        .buttonStyle(.link)
                    Button("Install from APK / folder…") { app.importAPK() }
                        .buttonStyle(.link)
                    Button("Rescan packages") { Task { await app.rescanPackages() } }
                        .buttonStyle(.link)
                    Button("Run setup again") { app.resetSetup() }
                        .buttonStyle(.link)
                    Spacer()
                }
                .font(.caption)
            }
            .padding(24)
        }
        .navigationTitle("BedrockHarbor")
        .task { await app.reload() }
    }
}

// MARK: - Settings

public struct SettingsView: View {
    public let app: AppState
    public init(app: AppState) { self.app = app }

    public var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Google Play", value: app.isPlaySignedIn ? app.playAccountLabel : "Not signed in")
                Button("Sign in again") {
                    Task { await app.googleSignIn(fresh: true) }
                }
                Button("Rescan packages") {
                    Task { await app.rescanPackages() }
                }
                Button("Show setup steps") {
                    app.resetSetup()
                }
            }
            Section("Doctor") {
                Button("Run checks") {
                    Task { await app.runDoctor() }
                }
                if !app.doctorLines.isEmpty {
                    ForEach(app.doctorLines, id: \.self) { line in
                        Text(line).font(.caption)
                    }
                }
            }
            Section("Xbox / Microsoft sign-in help") {
                Text("""
                If the in-game Microsoft sign-in gets stuck on "Face, fingerprint, PIN or security key": \
                Microsoft sometimes challenges embedded login windows with a passkey the window cannot open \
                (known upstream limitation, minecraft-linux issue #1523) — your account is fine.\n\n\
                Sign in with your password or PIN when offered, use "Use my password instead" or the other \
                verification links in the challenge, or complete sign-in on another device where the \
                challenge is available.\n\n\
                If sign-in still fails: check Diagnostics → Doctor and the session log for \
                mcpelauncher-webview errors. Llama error 0x80070057 means the helper's resources \
                are broken — Settings → Runtime → Reinstall.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Section("About") {
                LabeledContent("App", value: "BedrockHarbor")
                LabeledContent("License", value: "Apache-2.0")
            }
            Section("Credits") {
                Text(creditsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await app.reload() }
    }

    private var creditsText: String {
        """
        Runtime: minecraft-linux/mcpelauncher (macOS build), GPL-3.0
        Compatibility mod: minecraft-linux/mcpelauncher-updates via mcpelauncher-moddb
        Symbol shim & libc repair: BedrockHarbor, Apache-2.0
        Google Play client: BedrockHarbor independent client
        Game packages: user-owned; downloaded from Google Play by Harbor's Play client

        BedrockHarbor is not affiliated with Mojang, Microsoft, Google, or the minecraft-linux maintainers.
        """
    }
}

// MARK: - Root

@MainActor
@Observable
public final class HarborRootModel {
    public enum Item: String, CaseIterable, Identifiable, Hashable {
        case home = "Home"
        case settings = "Settings"
        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .home: return "house"
            case .settings: return "gearshape"
            }
        }
    }

    public var selection: Item = .home
    public let app: AppState

    public init(services: HarborServiceBundle) {
        self.app = AppState(services: services)
    }
}

public struct HarborRootView: View {
    public let model: HarborRootModel
    private let app: AppState

    public init(services: HarborServiceBundle) {
        self.model = HarborRootModel(services: services)
        self.app = model.app
    }

    public init(model: HarborRootModel) {
        self.model = model
        self.app = model.app
    }

    public var body: some View {
        Group {
            if app.needsOnboarding {
                OnboardingView(app: app)
            } else {
                NavigationSplitView {
                    VStack(spacing: 0) {
                        // Logo once at top — not on every nav row
                        HStack(spacing: 10) {
                            HarborLogo(size: 28)
                            Text("BedrockHarbor")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        Divider()

                        List(HarborRootModel.Item.allCases, selection: Binding(
                            get: { model.selection },
                            set: { if let v = $0 { model.selection = v } }
                        )) { item in
                            Label(item.rawValue, systemImage: item.icon)
                                .tag(item)
                        }
                        .listStyle(.sidebar)
                    }
                    .navigationSplitViewColumnWidth(min: 170, ideal: 190)
                } detail: {
                    switch model.selection {
                    case .home:
                        HomeView(app: app)
                    case .settings:
                        SettingsView(app: app)
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .task {
            await app.reload()
            app.refreshGate()
        }
    }
}
