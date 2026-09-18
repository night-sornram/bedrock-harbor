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
        accounts.contains { $0.sessionState == .ready }
    }

    public var nextStep: Int {
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
        status = "Local APK mode — choose an owned .apk if install finds nothing"
    }

    public func resetSetup() {
        usedLocalAPK = false
        needsOnboarding = true
        UserDefaults.standard.set(false, forKey: Self.onboardKey)
        refreshGate()
    }

    // MARK: Actions

    public func googleSignIn() async {
        signInBusy = true
        status = "Opening Google sign-in…"
        GoogleSignInController.shared.present()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: .bhGoogleSignInFinished, object: nil, queue: .main) { _ in
                if let token { NotificationCenter.default.removeObserver(token) }
                cont.resume()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                if let token { NotificationCenter.default.removeObserver(token) }
                cont.resume()
            }
        }
        if let email = GoogleSignInController.shared.signedInEmail {
            playAccountLabel = email
            let account = AccountRecord(
                providerID: .googlePlay,
                accountLabel: email,
                sessionState: .ready,
                keychainReference: "play-\(UUID().uuidString)"
            )
            accounts.removeAll { $0.providerID == .googlePlay }
            accounts.append(account)
            try? await services.metadata.saveAccounts(accounts)
            completeOnboardingFromLogin()
            status = "Signed in as \(email) — next: Install Minecraft"
        } else {
            status = "Google sign-in not finished — try again"
        }
        signInBusy = false
        await reload()
    }

    public func installGame() async {
        isInstalling = true
        defer { isInstalling = false }

        let local = await GamePackageAcquirer.acquire(services: services)
        if let existing = local.installation, existing.integrity == .verified {
            await reload()
            status = "Minecraft \(existing.originalVersionName) ready — Launch"
            return
        }

        status = "Checking Google Play…"
        let auth = await PlaySessionStore.harvestFromWebKit(email: playAccountLabel.isEmpty ? nil : playAccountLabel)
        if auth.cookies.isEmpty {
            status = "No Google Play session — sign in with the account that owns Minecraft"
            needsOnboarding = true
            refreshGate()
            return
        }

        let listing = await PlayStoreInspector().inspect(auth: auth)
        status = listing.summary

        if listing.showsOwned || listing.installOnDevices {
            // Try delivery anyway; if Google blocks unofficial clients, explain owned + blocked.
            status = "You already purchased — trying Play download for owned Minecraft…"
        } else if listing.showsBuy && !listing.showsOwned {
            status = "\(listing.summary). If you purchased Minecraft, sign in with that same Google account."
            return
        }

        status = "Downloading Minecraft from Google Play…"
        do {
            let staging = services.paths.stagingCache
                .appendingPathComponent("play-\(UUID().uuidString)", isDirectory: true)
            let result = try await PlayDeliveryClient().downloadPackage(auth: auth, into: staging)
            status = "Play download complete (\(result.fileCount) file(s)) — installing…"
            let version = result.versionName == "unknown" ? "play-\(result.fileCount)parts" : result.versionName
            let dest = GamePackageAcquirer.harborInstallRoot().appendingPathComponent(version, isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let apks = ((try? FileManager.default.contentsOfDirectory(at: result.packageDirectory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "apk" }
            if let extractor = findExtractor(), !apks.isEmpty {
                let process = Process()
                process.executableURL = extractor
                process.arguments = apks.map(\.path) + [dest.path]
                try process.run()
                process.waitUntilExit()
            } else if let first = apks.first {
                _ = try await GamePackageAcquirer.extractAPK(first, services: services)
                await reload()
                status = "Installed from Play download"
                return
            } else {
                status = ownedDeliveryBlockedMessage(listing)
                return
            }
            let install = try await GamePackageAcquirer.importIntoHarbor(from: dest, services: services)
            await reload()
            status = "Installed from Google Play — \(install.originalVersionName)"
        } catch {
            if listing.showsOwned || listing.installOnDevices {
                status = ownedDeliveryBlockedMessage(listing) + " Detail: \(error.localizedDescription)"
            } else {
                status = "Play install failed: \(error.localizedDescription) | \(listing.summary)"
            }
        }
    }

    private func ownedDeliveryBlockedMessage(_ listing: PlayStoreInspector.Listing) -> String {
        """
        Minecraft purchase is on this Play account (\(listing.summary)), but Google rejects Harbor's APK download \
        (DF-DFERH-01 / unofficial client). Install Minecraft on an Android phone with this account, \
        then use Install from APK / folder… — or keep waiting for a full Play client login in Harbor.
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
            status = error.localizedDescription
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
                Text("Signed in as \(app.playAccountLabel.isEmpty ? "Google Play" : app.playAccountLabel)")
                    .foregroundStyle(.green)
                    .font(.headline)
            }

            Button("I have an APK — skip Play") {
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
                        Button {
                            Task { await app.installGame() }
                        } label: {
                            Label(
                                app.isInstalling ? "Downloading from Play…" : "Install Minecraft from Play",
                                systemImage: "icloud.and.arrow.down"
                            )
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.isInstalling)
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
                    Button("Install from APK / folder…") { app.importAPK() }
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
                    Task { await app.googleSignIn() }
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
                Text("Unofficial project. Not affiliated with Mojang, Microsoft, or Google.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await app.reload() }
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
