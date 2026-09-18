import AppKit
import Foundation
import HarborApplication
import HarborDomain
import HarborGooglePlay
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
    public var playAccountLabel = ""
    public var accounts: [AccountRecord] = []
    public var needsOnboarding = true
    public var doctorLines: [String] = []

    public let services: HarborServiceBundle
    private var sessionCoordinator: GameSessionCoordinator?

    private static let localAPKKey = "com.bedrockharbor.localapk.mode"
    private static let onboardKey = "com.bedrockharbor.onboarding.completed"

    public init(services: HarborServiceBundle) {
        self.services = services
        self.sessionCoordinator = GameSessionCoordinator(services: services)
        self.needsOnboarding = !UserDefaults.standard.bool(forKey: Self.localAPKKey)
    }

    public var selectedProfile: Profile? {
        profiles.first { $0.id == selectedProfileID }
            ?? profiles.first { $0.selectedInstallationID != nil }
            ?? profiles.first
    }

    public var gameInstallation: InstalledMinecraft? {
        installations.first { $0.integrity == .verified }
            ?? installations.first
    }

    public var runtime: RuntimeInstallation? { runtimes.first }

    public var hasVerifiedGame: Bool { gameInstallation?.integrity == .verified }

    public var isPlaySignedIn: Bool {
        if HarborPlayTokenBridge.loadOAuthToken() != nil { return true }
        if PlaySessionStore.load().cookies["oauth_token"] != nil { return true }
        return accounts.contains { $0.sessionState == .ready && $0.accountLabel.contains("@") }
    }

    public var nextStep: Int {
        if !hasVerifiedGame && (isPlaySignedIn || usedLocalAPK) { return 2 }
        if !isPlaySignedIn && !usedLocalAPK { return 1 }
        if !hasVerifiedGame { return 2 }
        return 3
    }

    public var usedLocalAPK: Bool {
        get { UserDefaults.standard.bool(forKey: Self.localAPKKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.localAPKKey) }
    }

    public func refreshGate() {
        if isPlaySignedIn || usedLocalAPK {
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
        if let ready = accounts.first(where: { $0.sessionState == .ready }) {
            playAccountLabel = ready.accountLabel
        }
        if selectedProfileID == nil { selectedProfileID = profiles.first?.id }
        refreshGate()
        status = status.isEmpty ? readySummary() : status
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
        status = "Local package mode — Import APK or Rescan after Minecraft Bedrock Launcher downloads"
        refreshGate()
    }

    public func openPackageSourceLauncher() {
        let candidates = [
            "/Applications/Minecraft Bedrock Launcher.app",
            homeMinecraftBedrockLauncherPath(),
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            status = "Minecraft Bedrock Launcher opened. Sign in with Google Play there, download Minecraft, then press Rescan packages in Harbor."
            return
        }
        status = "Minecraft Bedrock Launcher not installed. Use Install from APK / folder… with an owned package."
    }

    private func homeMinecraftBedrockLauncherPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BedrockHarbor/Runtimes/_downloads")
            .path
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
            status = "No Minecraft package found. Use Minecraft Bedrock Launcher to download once, or Install from APK / folder…"
        }
    }

    public func resetSetup() {
        usedLocalAPK = false
        needsOnboarding = true
        UserDefaults.standard.set(false, forKey: Self.onboardKey)
        refreshGate()
    }

    // MARK: Actions

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
        isInstalling = true
        defer { isInstalling = false }

        // Prefer any package already on disk before Play network paths.
        let local = await GamePackageAcquirer.acquire(services: services)
        if let existing = local.installation, existing.integrity == .verified {
            await reload()
            status = "Minecraft \(existing.originalVersionName) ready — Launch"
            return
        }

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
            await googleSignIn(fresh: true)
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
                    await googleSignIn(fresh: true)
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
                    let process = Process()
                    process.executableURL = extractor
                    process.arguments = files.map(\.fileURL.path) + [dest.path]
                    try process.run()
                    process.waitUntilExit()
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

    /// Clear UX when Google will not hand APKs to Harbor. Package source is the working path.
    private static func packageNeededMessage(details: String) -> String {
        """
        Harbor cannot download Minecraft APK from Google Play right now (unofficial client blocked).\n\n\
        Working ways to get the owned package:\n\
        1) Open Minecraft Bedrock Launcher → Google Play login → download Minecraft → Harbor Rescan packages\n\
        2) Home → Install from APK / folder… (owned base.apk or game folder with lib/arm64-v8a/libminecraftpe.so)\n\n\
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
        await coordinator.reconcileExited()
        isGameRunning = false
        status = "Stop requested"
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
                    subtitle: "Required — account that owns Minecraft",
                    done: app.isPlaySignedIn,
                    active: app.nextStep == 1
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

            Button {
                app.openPackageSourceLauncher()
            } label: {
                Label("Open Minecraft Bedrock Launcher to download package", systemImage: "shippingbox")
            }
            .buttonStyle(.bordered)

            Button("I have an APK — skip Play download") {
                app.useLocalAPK()
            }
            .buttonStyle(.link)
            .font(.caption)

            if !app.status.isEmpty {
                Text(app.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
        .task { await app.reload() }
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

                            Button {
                                app.openPackageSourceLauncher()
                            } label: {
                                Label("Open Minecraft Bedrock Launcher (Play download source)", systemImage: "shippingbox")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

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
                    Button("Package source launcher…") { app.openPackageSourceLauncher() }
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
                Button("Open package source launcher") {
                    app.openPackageSourceLauncher()
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
        Game packages: user-owned imports; downloads via the official Minecraft Bedrock Launcher

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
