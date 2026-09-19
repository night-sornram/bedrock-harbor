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
    public let optional: Bool
    public init(n: Int, title: String, subtitle: String, done: Bool, active: Bool, optional: Bool = false) {
        self.n = n
        self.title = title
        self.subtitle = subtitle
        self.done = done
        self.active = active
        self.optional = optional
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
                        .accessibilityLabel("Done")
                } else if optional {
                    Image(systemName: "minus").foregroundStyle(.secondary)
                        .accessibilityLabel("Optional")
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
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Operation phase surface

/// Renders an `OperationTracker` phase: spinner + stage label while working,
/// green completion text when done, short failure text plus a recovery button
/// when failed. Standard controls only — no custom animation.
struct OperationPhaseView: View {
    let tracker: OperationTracker
    let onRecovery: (OperationTracker.Recovery) -> Void

    var body: some View {
        switch tracker.phase {
        case .idle:
            EmptyView()
        case .working(let label):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message, let recovery):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                if let recovery {
                    Button(recovery.title) { onRecovery(recovery) }
                }
            }
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
        .accessibilityElement(children: .combine)
    }
}

// MARK: - State

/// Posted once the startup bootstrap (runtime self-heal, metadata repair, package
/// acquisition) has finished — it can run for ~40 s after a data wipe, well past
/// the UI's first metadata read. AppState reloads on it so the Play screen cannot
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
    public var isGameRunning = false
    public var isInstalling = false
    public var signInBusy: Bool { playSession.status.isBusy }
    /// Active download progress (0...1); nil when nothing measurable is downloading.
    /// Percentages are shown for downloads only — launch stages are named, not faked.
    public var downloadProgress: Double?
    public var downloadDetail = ""
    public var downloadLabel = ""
    public var playAccountLabel: String { playSession.status.email ?? "" }
    public var accounts: [AccountRecord] = []
    /// Internal first-run hint. Never gates navigation — the app always opens on
    /// Play; the readiness checklist there shows what is missing instead.
    public var needsOnboarding = true
    public var doctorFindings: [DoctorFinding] = []

    // Worlds ("maps") of the selected profile. Refreshed on section entry and
    // after import/export — never per render.
    public internal(set) var worlds: [MinecraftWorld] = []
    public var hasProfileForWorlds: Bool { selectedProfile != nil }

    // Installation snapshots are refreshed outside SwiftUI rendering. Google
    // status comes exclusively from the shared session coordinator.
    public var gameInstallation: InstalledMinecraft?
    public var runtime: RuntimeInstallation?
    public var hasVerifiedGame = false
    public var isPlaySignedIn: Bool { playSession.status.isSignedIn }
    public let playSession: PlaySessionCoordinator
    public var googlePlayStepIsComplete: Bool { isPlaySignedIn }
    public var googlePlayStepIsOptional: Bool { !isPlaySignedIn && (hasVerifiedGame || usedLocalAPK) }
    /// Snapshot of the "user plays from a local package" default (Task 6
    /// pattern): written via `useLocalAPK()` / `resetSetup()`, read from
    // UserDefaults only inside `refreshDerivedState()` — never per render.
    public private(set) var usedLocalAPK = false

    // Structured operation state (replaces the old status string): one tracker
    // per UI concern so sections never overwrite each other's phases.
    public let playOperations = OperationTracker()
    public let installOperations = OperationTracker()
    public let accountOperations = OperationTracker()
    public let maintenanceOperations = OperationTracker()
    public let diagnosticsOperations = OperationTracker()
    public let worldsOperations = OperationTracker()

    /// Live launch stages, driven by the supervisor's RuntimeEvent stream.
    public let launchProgress = LaunchProgressTracker()
    /// Local mirror of the coordinator's launch reservation: true from the
    /// moment a launch begins (before its first suspension) until a terminal
    /// RuntimeEvent resets it — so Play auto-restores after exit or failure.
    public internal(set) var launchInFlight = false
    private var cancelLaunchRequested = false

    public let services: HarborServiceBundle
    private var sessionCoordinator: GameSessionCoordinator?
    private let bootstrapBox = ObserverBox()

    private static let localAPKKey = "com.bedrockharbor.localapk.mode"
    private static let onboardKey = "com.bedrockharbor.onboarding.completed"

    /// Test seam: overrides the settings defaults (nil in production → .standard).
    nonisolated(unsafe) public static var defaultsOverride: UserDefaults?
    private static var defaults: UserDefaults { defaultsOverride ?? .standard }

    /// Process name of the runtime's Microsoft sign-in helper (Qt webview).
    private static let microsoftHelperProcessName = "mcpelauncher-webview"
    /// The helper spawns only when the player opens Microsoft sign-in in-game —
    /// often minutes into a session — so its spawn watcher gets a longer bound
    /// than the default. Marks after the timing session ends are ignored.
    private static let microsoftHelperWatchTimeout: TimeInterval = 600

    public init(services: HarborServiceBundle, playSession: PlaySessionCoordinator? = nil) {
        self.playSession = playSession ?? PlaySessionCoordinator(backend: LivePlaySessionBackend(metadata: services.metadata))
        self.services = services
        self.sessionCoordinator = GameSessionCoordinator(services: services)
        self.needsOnboarding = !Self.defaults.bool(forKey: Self.localAPKKey)
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

    /// Recomputes installation readiness from freshly loaded metadata.
    /// Runs inside `reload()` and after
    /// mutating actions — never from a SwiftUI `body`.
    func refreshDerivedState() {
        let profile = selectedProfile
        usedLocalAPK = Self.defaults.bool(forKey: Self.localAPKKey)

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
    }

    public var nextStep: Int {
        if hasVerifiedGame { return 3 }
        if isPlaySignedIn || usedLocalAPK { return 2 }
        return 1
    }

    public func refreshGate() {
        // Internal hint only: a verified local game package is enough to play —
        // Google Play sign-in is only needed for store features. Nothing in the
        // UI is gated on this anymore.
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
        playSession.restoreIfNeeded()
        if selectedProfileID == nil { selectedProfileID = profiles.first?.id }
        refreshDerivedState()
        refreshGate()
    }

    public func completeOnboardingFromLogin() {
        needsOnboarding = false
        Self.defaults.set(true, forKey: Self.onboardKey)
        refreshGate()
    }

    public func useLocalAPK() {
        Self.defaults.set(true, forKey: Self.localAPKKey)
        usedLocalAPK = true
        needsOnboarding = false
        installOperations.succeed("Local package mode — Install from APK / folder… or Rescan packages")
        refreshDerivedState()
        refreshGate()
    }

    public func rescanPackages() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        installOperations.begin("Scanning for Minecraft packages…")
        // Explicit user action: full scope (Downloads/Desktop/other launchers).
        let result = await GamePackageAcquirer.acquire(services: services)
        await reload()
        if let install = result.installation {
            installOperations.succeed("Package ready: \(install.originalVersionName) — back to Play")
        } else {
            installOperations.fail("No Minecraft package found on this Mac.", recovery: .installGame)
        }
    }

    public func resetSetup() {
        Self.defaults.set(false, forKey: Self.localAPKKey)
        usedLocalAPK = false
        needsOnboarding = true
        Self.defaults.set(false, forKey: Self.onboardKey)
        refreshDerivedState()
        refreshGate()
        maintenanceOperations.succeed("Setup reset — the readiness checklist on Play shows what is missing")
    }

    // MARK: Actions

    /// The Minecraft Bedrock Launcher runtime ships mcpelauncher-extract + mcpelauncher-client.
    /// When it is missing (fresh Mac, wiped data) Harbor installs it automatically —
    /// no manual script step. Phase/progress updates go to `tracker` so callers
    /// (Play self-heal, install, import) surface them on their own screen.
    @discardableResult
    public func ensureLauncherRuntimeInstalled(tracker: OperationTracker) async -> Bool {
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
        tracker.begin("Installing Minecraft Bedrock Launcher…")
        defer { downloadProgress = nil }
        downloadLabel = "Minecraft Bedrock Launcher"
        do {
            _ = try await HarborRuntimeInstaller.ensureInstalled(status: { text in
                Task { @MainActor in
                    tracker.begin(text)
                    if let pctToken = text.range(of: #"\d+%"#, options: .regularExpression),
                       let percent = Double(text[pctToken].dropLast()) {
                        self.downloadProgress = percent / 100
                        self.downloadDetail = ""
                    }
                }
            })
        } catch {
            tracker.fail(
                "Launcher runtime install failed: \(OperationTracker.shortMessage(for: error))",
                recovery: .reinstallRuntime
            )
            return false
        }
        // Persist the freshly installed runtime so Launch works in this same session.
        guard let bundle = LocalRuntimeDiscovery().discoverDefault() else {
            tracker.fail("Launcher runtime installed but not detected — restart Harbor.", recovery: .openSettings)
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
        tracker.begin("Launcher runtime installed — continuing…")
        return true
    }

    private final class ObserverBox: @unchecked Sendable {
        var token: NSObjectProtocol?
    }

    public func googleSignIn(fresh: Bool = false) async {
        guard !signInBusy else { return }
        accountOperations.reset()
        await playSession.signIn(fresh: fresh)
        await reload()
    }

    public func googleSignOut() async {
        guard !isInstalling else { return }
        accountOperations.reset()
        await playSession.signOut()
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
        installOperations.begin("Looking for a package already on this Mac…")
        let local = await GamePackageAcquirer.acquire(services: services, scope: .startup)
        if let existing = local.installation, existing.integrity == .verified {
            await reload()
            installOperations.succeed("Minecraft \(existing.originalVersionName) ready — back to Play")
            return
        }

        // APK extraction needs mcpelauncher-extract — install the launcher runtime first.
        guard await ensureLauncherRuntimeInstalled(tracker: installOperations) else { return }

        installOperations.begin("Checking Google Play session…")
        playSession.restoreIfNeeded()
        await playSession.waitForValidation()
        if playSession.status == .signedOut { await googleSignIn() }
        guard isPlaySignedIn else {
            installOperations.fail("Google Play sign-in has not been verified. Check your session in Accounts.", recovery: .signIn)
            return
        }
        var auth = PlaySessionStore.load()
        var oauth = HarborPlayTokenBridge.loadOAuthToken() ?? auth.cookies["oauth_token"]

        // Resolve email/user_id without bouncing to login when token already exists.
        var email = playAccountLabel.contains("@") ? playAccountLabel : nil
        if email == nil, auth.accountEmail?.contains("@") == true { email = auth.accountEmail }
        if email == nil, let e = auth.cookies["Email"], e.contains("@") { email = e }
        if email == nil, let e = HarborPlayTokenBridge.loadAccountEmail() { email = e }
        let userID = auth.cookies["user_id"] ?? email ?? "play-user"

        if email == nil || playAccountLabel == "Google Play account" || playAccountLabel.isEmpty {
            let listing = await PlayStoreInspector().inspect(auth: auth)
            if let e = listing.accountEmail { email = e; HarborPlayTokenBridge.saveAccountEmail(e) }
            installOperations.begin("Play client token ready. \(listing.summary)")
        } else if let email {
            installOperations.begin("Signed in as \(email) — installing with Harbor Play client…")
        } else {
            installOperations.begin("Play client token ready — installing with Harbor Play client…")
        }
        // Community Google-Play-API client first: Google's delivery gateway
        // rejects Harbor's own client (HTTP 400) but accepts this one. First
        // run exchanges the sign-in access token for a master token that
        // gplaydl persists; later runs need no sign-in at all.
        downloadLabel = "Minecraft"
        if let gplay = await GPlayDLClient.download(
            oauth: oauth,
            email: email,
            status: { self.installOperations.begin($0) },
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
                    installOperations.succeed("Installed via Google-Play-API client — \(install.originalVersionName)")
                    return
                } else if let first = gplay.files.first {
                    _ = try await GamePackageAcquirer.extractAPK(first, services: services)
                    try? FileManager.default.removeItem(at: gplay.stagingDir)
                    await reload()
                    installOperations.succeed("Installed via Google-Play-API client")
                    return
                }
            } catch {
                installOperations.begin("Google-Play-API install failed: \(OperationTracker.shortMessage(for: error)) — trying Harbor client…")
            }
        }

        // A credential may have expired since the background check. Do not
        // keep showing a verified account while trying stale fallback tokens.
        await playSession.retry()
        guard isPlaySignedIn else {
            installOperations.fail("Google Play could not verify this session. Check Accounts before retrying.", recovery: .signIn)
            return
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
            installOperations.begin("Play client authorized — downloading…")
        } catch let error as HarborError {
            switch error {
            case .reauthenticationRequired:
                // Only re-login when we truly have no Play token. "Sign in again" is not the default.
                if oauth == nil {
                    installOperations.fail("No Play client token — opening Android Google setup once.", recovery: .signIn)
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
                        installOperations.fail(
                            "oauth_token still missing. Accounts → Sign in again (fresh), finish Android setup until it shows oauth_token.",
                            recovery: .signInFresh
                        )
                    }
                } else {
                    installOperations.fail("Play token exists; Google still rejected auth — token exchange failed. Do not sign in again.")
                }
            case .providerFailure(let reason):
                installOperations.fail(
                    "\(reason) — if oauth_token is already captured, do not Sign in again; use a fresh setup only when the token is missing, or Import from APK.",
                    recovery: .importPackage
                )
            default:
                installOperations.fail(OperationTracker.shortMessage(for: error), recovery: OperationTracker.recovery(for: error))
            }
        } catch {
            installOperations.fail(OperationTracker.shortMessage(for: error))
        }

        if let credential {
            do {
                let version = try await client.latestVersion(credential: credential)
                installOperations.begin("Play version \(version.versionName ?? String(version.versionCode)) — downloading…")
                let staging = services.paths.stagingCache
                    .appendingPathComponent("harbor-play-\(UUID().uuidString)", isDirectory: true)
                let files = try await client.downloadDelivery(
                    versionCode: version.versionCode,
                    credential: credential,
                    outputDirectory: staging
                )
                installOperations.begin("Downloaded \(files.count) APK file(s) — installing…")
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
                    installOperations.succeed("Installed via Harbor Play client")
                    return
                }
                let install = try await GamePackageAcquirer.importIntoHarbor(from: dest, services: services)
                await reload()
                installOperations.succeed("Installed via Harbor Play client — \(install.originalVersionName)")
                return
            } catch {
                installOperations.fail("Harbor Play download failed: \(OperationTracker.shortMessage(for: error))", recovery: .rescan)
                return
            }
        }

        // Signed-in fallback: cookie-based Play probe (does not require another login).
        installOperations.begin("Trying Play download with existing session…")
        do {
            let staging = services.paths.stagingCache
                .appendingPathComponent("play-web-\(UUID().uuidString)", isDirectory: true)
            let result = try await PlayDeliveryClient().downloadPackage(auth: auth, into: staging)
            installOperations.begin("Play session download complete (\(result.fileCount)) — installing…")
            let apks = ((try? FileManager.default.contentsOfDirectory(at: result.packageDirectory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "apk" }
            if let first = apks.first {
                _ = try await GamePackageAcquirer.extractAPK(first, services: services)
                await reload()
                installOperations.succeed("Installed from Play session download")
            } else {
                installOperations.fail("Play returned no APK files.", recovery: .importPackage)
            }
        } catch {
            installOperations.fail(
                "Google Play did not deliver Minecraft — check that your account owns it, run setup again, or import an owned APK. (\(OperationTracker.shortMessage(for: error)))",
                recovery: .importPackage
            )
        }
        await reload()
    }

    public func openPlayStoreListing() {
        NSWorkspace.shared.open(PlayStoreInspector.detailsURL)
        installOperations.succeed("Opened Minecraft on Google Play — you can install to an Android device from there")
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
            installOperations.reset()
            return
        }
        let services = self.services
        Task {
            installOperations.begin("Installing \(url.lastPathComponent)…")
            do {
                let install: InstalledMinecraft
                if url.pathExtension.lowercased() == "apk" {
                    guard await self.ensureLauncherRuntimeInstalled(tracker: installOperations) else { return }
                    install = try await GamePackageAcquirer.extractAPK(url, services: services)
                } else {
                    install = try await GamePackageAcquirer.importIntoHarbor(from: url, services: services)
                }
                await reload()
                installOperations.succeed("Installed \(install.originalVersionName)")
            } catch {
                installOperations.fail(
                    "Import failed: \(OperationTracker.shortMessage(for: error))",
                    recovery: OperationTracker.recovery(for: error)
                )
            }
        }
    }

    // MARK: Worlds (maps)

    /// World files are LevelDB — locked while the game runs. One guard for
    /// both directions of transfer, checked before any panel or copy work.
    private var worldTransferBlocked: Bool {
        isGameRunning || launchInFlight
    }

    public func loadWorlds() async {
        guard let profile = selectedProfile else {
            worlds = []
            return
        }
        worlds = await WorldArchiveService.listWorlds(
            profileDataURL: services.paths.profileDataURL(dataRootID: profile.dataRootID)
        )
    }

    public func exportWorld(_ world: MinecraftWorld) {
        guard !worldTransferBlocked else {
            worldsOperations.fail("Close Minecraft first — world files are locked while the game runs.")
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = WorldArchiveService.sanitizedFileName(for: world)
        panel.message = "Export “\(world.name)” as a .mcworld world file"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else {
            worldsOperations.reset()
            return
        }
        worldsOperations.begin("Packing “\(world.name)”…")
        Task {
            do {
                try await WorldArchiveService.exportWorld(world, to: url)
                worldsOperations.succeed("Exported \(url.lastPathComponent)")
            } catch {
                worldsOperations.fail("Export failed: \(OperationTracker.shortMessage(for: error))")
            }
        }
    }

    public func importWorldFromPanel() {
        guard !worldTransferBlocked else {
            worldsOperations.fail("Close Minecraft first — world files are locked while the game runs.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a .mcworld / .zip world file, or an extracted world folder"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else {
            worldsOperations.reset()
            return
        }
        worldsOperations.begin("Importing \(url.lastPathComponent)…")
        Task {
            do {
                guard let profile = selectedProfile else {
                    throw HarborError.internalInconsistency(reason: "No profile to import into")
                }
                let imported = try await WorldArchiveService.importWorld(
                    from: url,
                    profileDataURL: services.paths.profileDataURL(dataRootID: profile.dataRootID)
                )
                await loadWorlds()
                worldsOperations.succeed("Imported “\(imported.name)”")
            } catch {
                worldsOperations.fail("Import failed: \(OperationTracker.shortMessage(for: error))")
            }
        }
    }

    /// Makes the profile's selected installation the one Play launches.
    public func selectInstallation(_ installation: InstalledMinecraft) async {
        guard var profile = selectedProfile,
              profile.selectedInstallationID != installation.id
        else { return }
        profile.selectedInstallationID = installation.id
        do {
            try await ProfileWorkflow(services: services).update(profile)
        } catch {
            installOperations.fail("Could not select installation: \(OperationTracker.shortMessage(for: error))")
            return
        }
        await reload()
        installOperations.succeed("Profile “\(profile.name)” now uses \(installation.originalVersionName)")
    }

    // MARK: Launch

    public func launchGame() async {
        if nextStep == 1 && !usedLocalAPK {
            playOperations.fail("Sign in with Google Play first — or import a package you already own.", recovery: .signIn)
            return
        }
        if !hasVerifiedGame {
            await installGame()
            guard hasVerifiedGame else {
                playOperations.fail("Minecraft is not installed yet.", recovery: .installGame)
                return
            }
        }
        guard !launchInFlight, !isGameRunning else { return }
        cancelLaunchRequested = false
        // Local mirror of the coordinator's reservation: Play is disabled from
        // this moment — before the first suspension below — until a terminal
        // RuntimeEvent restores it.
        launchInFlight = true
        launchProgress.begin(.verifyingPackage)
        playOperations.begin(LaunchProgress.verifyingPackage.label)
        guard let profile = selectedProfile,
              let installation = gameInstallation
        else {
            launchInFlight = false
            launchProgress.clear()
            playOperations.fail("Missing profile or game installation.", recovery: .openSettings)
            return
        }
        do {
            let verified = try await GameSessionCoordinator.verifyInstallation(installation, services: services)
            try throwIfCancelled()
            guard verified.integrity == .verified else {
                throw HarborError.invalidPackage(
                    reason: "Game package not verified under \(installation.relativeGameDirectory)"
                )
            }
            if runtime == nil {
                // Last-resort self-heal (startup install may have failed while offline).
                launchProgress.begin(.checkingRuntime)
                playOperations.begin(LaunchProgress.checkingRuntime.label)
                guard await ensureLauncherRuntimeInstalled(tracker: playOperations) else {
                    throw HarborError.unsupportedRuntime(reason: "Launcher runtime could not be installed")
                }
            }
            try throwIfCancelled()
            guard let runtime else {
                throw HarborError.unsupportedRuntime(reason: "No launcher runtime available")
            }
            launchProgress.begin(.preparingCompatibility)
            playOperations.begin(LaunchProgress.preparingCompatibility.label)
            let coordinator = sessionCoordinator ?? GameSessionCoordinator(services: services)
            sessionCoordinator = coordinator
            launchProgress.begin(.launching)
            playOperations.begin(LaunchProgress.launching.label)
            let session = try await coordinator.launch(profile: profile, installation: verified, runtime: runtime)
            isGameRunning = true
            playOperations.succeed("Minecraft running (pid \(session.processIdentifier.map(String.init) ?? "?"))")
            observeSessionEvents(sessionID: session.id)
            startLaunchWindowWatchers(session: session)
            if cancelLaunchRequested { await stopGame() }
        } catch {
            isGameRunning = false
            launchInFlight = false
            launchProgress.clear()
            if let harbor = error as? HarborError, harbor == .cancelled {
                playOperations.reset()
            } else {
                let msg = error.localizedDescription
                if msg.lowercased().contains("pthread_sigmask")
                    || msg.lowercased().contains("cannot locate symbol")
                    || msg.lowercased().contains("failed to load minecraft")
                    || msg.lowercased().contains("please reinstall or wait") {
                    playOperations.fail(
                        "Minecraft \(installation.originalVersionName) failed to start — run Doctor or re-import the APK.",
                        recovery: .runDoctor
                    )
                } else {
                    playOperations.fail(
                        OperationTracker.shortMessage(for: error),
                        recovery: OperationTracker.recovery(for: error)
                    )
                }
            }
        }
    }

    /// True only while a launch is still preparing: reserved, no process yet,
    /// and not already stopping. Drives the Cancel button — after Stop is
    /// pressed (`isGameRunning` drops, stage `.stopping`, reservation held
    /// until the terminal event) nothing is cancellable anymore.
    public var canCancelLaunchPreparation: Bool {
        launchInFlight && !isGameRunning && launchProgress.stage != .stopping
    }

    /// Stop once the game process exists; cancel while still preparing.
    public func requestCancelLaunch() async {
        guard launchInFlight else { return }
        if isGameRunning {
            await stopGame()
        } else if launchProgress.stage != .stopping {
            // Guarded on stage too: a Stop already in progress must keep its
            // "Stopping Minecraft" label — there is nothing left to cancel.
            cancelLaunchRequested = true
            playOperations.begin("Cancelling…")
        }
    }

    public func stopGame() async {
        guard let coordinator = sessionCoordinator else { return }
        launchProgress.begin(.stopping)
        playOperations.begin(LaunchProgress.stopping.label)
        try? await coordinator.requestStop()
        // No reconcileExited() here: the coordinator releases the lease itself
        // once the runtime confirms the process exited (terminal RuntimeEvent).
        isGameRunning = false
    }

    private func throwIfCancelled() throws {
        if cancelLaunchRequested { throw HarborError.cancelled }
    }

    /// Applies a supervisor runtime event to the live launch UI state.
    /// Returns true when the event was terminal — the session ended and Play
    /// availability must be restored.
    @discardableResult
    func applyRuntimeEvent(_ event: RuntimeEvent) -> Bool {
        guard LaunchProgress.isTerminal(event) else {
            launchProgress.apply(event)
            return false
        }
        launchProgress.clear()
        launchInFlight = false
        isGameRunning = false
        if event.kind == .failed {
            let detail = event.message.map { " \($0)" } ?? ""
            playOperations.fail("Minecraft exited unexpectedly\(detail).", recovery: .runDoctor)
        } else {
            playOperations.succeed("Game closed — Play is ready again")
        }
        return true
    }

    /// Subscribes to the supervisor's event fan-out for one session: live
    /// stages while it runs, and the terminal event that restores Play.
    private func observeSessionEvents(sessionID: UUID) {
        guard let launcher = services.runtimeLauncher else { return }
        Task { @MainActor in
            var sawTerminal = false
            for await event in launcher.events(sessionID: sessionID) {
                if self.applyRuntimeEvent(event) {
                    sawTerminal = true
                    break
                }
            }
            if !sawTerminal {
                // Stream ended without a terminal event (launcher without event
                // support): the coordinator's fallback cleanup plus a local
                // reset, so Play can never stay disabled.
                await self.sessionCoordinator?.reconcileExited()
                self.launchProgress.clear()
                self.launchInFlight = false
                self.isGameRunning = false
            }
        }
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

    // MARK: Diagnostics

    public func runDoctor() async {
        diagnosticsOperations.begin("Running checks…")
        do {
            let snap = try await DiagnosticsWorkflow(services: services).collect()
            doctorFindings = snap.findings
            diagnosticsOperations.succeed("Doctor finished — \(snap.findings.count) checks")
        } catch {
            diagnosticsOperations.fail("Doctor failed: \(OperationTracker.shortMessage(for: error))")
        }
    }

    /// Recent launch-timing sessions (newest last) for the Diagnostics table.
    public func loadLaunchTimings() -> [LaunchTimingRecord] {
        LaunchTimingRecorder.recentRecords(directory: services.paths.metadataDirectory)
    }

    /// Writes the redacted diagnostics bundle (doctor-preview.json) into a
    /// user-chosen directory.
    public func exportDiagnostics(to directory: URL) async {
        diagnosticsOperations.begin("Collecting diagnostics…")
        do {
            let collector = FoundationDiagnosticsCollector(workflow: DiagnosticsWorkflow(services: services))
            let url = try await collector.exportBundle(to: directory)
            diagnosticsOperations.succeed("Exported \(url.lastPathComponent) to “\(directory.lastPathComponent)”")
        } catch {
            diagnosticsOperations.fail("Export failed: \(OperationTracker.shortMessage(for: error))")
        }
    }

    // MARK: Settings actions

    /// Force reinstall of the launcher runtime (Settings → Runtime maintenance):
    /// downloads + deploys via the same installer used by the self-heal path,
    /// with the shared download-progress plumbing.
    public func reinstallRuntime() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer {
            isInstalling = false
            downloadProgress = nil
        }
        maintenanceOperations.begin("Reinstalling Minecraft Bedrock Launcher…")
        downloadLabel = "Minecraft Bedrock Launcher"
        do {
            try await HarborRuntimeInstaller.install(status: { text in
                Task { @MainActor in
                    self.maintenanceOperations.begin(text)
                    if let pctToken = text.range(of: #"\d+%"#, options: .regularExpression),
                       let percent = Double(text[pctToken].dropLast()) {
                        self.downloadProgress = percent / 100
                        self.downloadDetail = ""
                    }
                }
            })
            guard let bundle = LocalRuntimeDiscovery().discoverDefault() else {
                maintenanceOperations.fail("Launcher installed but not detected — restart Harbor.", recovery: .openSettings)
                return
            }
            var runtimes = (try? await services.metadata.loadRuntimeInstallations()) ?? []
            if let i = runtimes.firstIndex(where: { $0.releaseID == bundle.runtimeInstallation.releaseID }) {
                runtimes[i] = bundle.runtimeInstallation
            } else {
                runtimes.append(bundle.runtimeInstallation)
            }
            try? await services.metadata.saveRuntimeInstallations(runtimes)
            await reload()
            maintenanceOperations.succeed("Launcher runtime reinstalled")
        } catch {
            maintenanceOperations.fail(
                "Runtime reinstall failed: \(OperationTracker.shortMessage(for: error))",
                recovery: .reinstallRuntime
            )
        }
    }

    /// Refreshes the mcpelauncher-updates compatibility catalog now (throws on
    /// network failure — no silent offline fallback).
    public func refreshCompatibilityPatches() async {
        guard !maintenanceOperations.isWorking else { return }
        maintenanceOperations.begin("Refreshing compatibility patches…")
        do {
            let url = try await HarborCompatibilityPatches.refreshCatalogNow()
            maintenanceOperations.succeed("Compatibility patches refreshed (\(url.lastPathComponent))")
        } catch {
            maintenanceOperations.fail(
                "Patch refresh failed: \(OperationTracker.shortMessage(for: error))",
                recovery: OperationTracker.recovery(for: error)
            )
        }
    }

    public func deleteProfile(_ profile: Profile) async {
        if let workflow = ProfileWorkflow(services: services) as ProfileWorkflow? {
            try? await workflow.delete(id: profile.id)
        }
        await reload()
        playOperations.succeed("Deleted profile \(profile.name)")
    }
}

// MARK: - Root

@MainActor
@Observable
public final class HarborRootModel {
    public enum Item: String, CaseIterable, Identifiable, Hashable {
        case play = "Play"
        case worlds = "Worlds"
        case installations = "Installations"
        case accounts = "Accounts"
        case diagnostics = "Diagnostics"
        case settings = "Settings"
        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .play: return "play.circle"
            case .worlds: return "map"
            case .installations: return "square.and.arrow.down"
            case .accounts: return "person.crop.circle"
            case .diagnostics: return "stethoscope"
            case .settings: return "gearshape"
            }
        }
    }

    public var selection: Item = .play
    public let app: AppState

    public init(services: HarborServiceBundle) {
        self.app = AppState(services: services)
    }

    /// Executes a recovery action from a failure surface: navigates to the
    /// section that owns the fix and starts it.
    public func handle(_ recovery: OperationTracker.Recovery) {
        switch recovery {
        case .installGame:
            selection = .installations
            Task { await app.installGame() }
        case .signIn:
            selection = .accounts
            Task { await app.googleSignIn() }
        case .signInFresh:
            selection = .accounts
            Task { await app.googleSignIn(fresh: true) }
        case .importPackage:
            selection = .installations
            app.importAPK()
        case .rescan:
            selection = .installations
            Task { await app.rescanPackages() }
        case .reinstallRuntime:
            selection = .settings
            Task { await app.reinstallRuntime() }
        case .runDoctor:
            selection = .diagnostics
            Task { await app.runDoctor() }
        case .openSettings:
            selection = .settings
        }
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
            // No onboarding wall: navigation is always available, every screen
            // shows its own missing requirements, and first-run users land on
            // Play with the embedded readiness checklist.
            switch model.selection {
            case .play:
                PlayView(app: app, onRecovery: model.handle)
            case .worlds:
                WorldsView(app: app, onRecovery: model.handle)
            case .installations:
                InstallationsView(app: app, onRecovery: model.handle)
            case .accounts:
                AccountsView(app: app, onRecovery: model.handle)
            case .diagnostics:
                DiagnosticsView(app: app, onRecovery: model.handle)
            case .settings:
                SettingsView(app: app, onRecovery: model.handle)
            }
        }
        .task {
            await app.reload()
            app.refreshGate()
        }
    }
}
