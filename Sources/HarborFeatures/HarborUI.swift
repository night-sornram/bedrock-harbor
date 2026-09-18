import Foundation
import HarborDomain
import HarborApplication
import SwiftUI

// MARK: - Shared UI components

public struct StatusBadge: View {
    public let text: String
    public let tone: Tone

    public enum Tone {
        case neutral, ok, warning, critical
    }

    public init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
            .accessibilityLabel(text)
    }

    private var background: Color {
        switch tone {
        case .neutral: return Color.secondary.opacity(0.15)
        case .ok: return Color.green.opacity(0.18)
        case .warning: return Color.orange.opacity(0.2)
        case .critical: return Color.red.opacity(0.2)
        }
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return Color.secondary
        case .ok: return Color.green
        case .warning: return Color.orange
        case .critical: return Color.red
        }
    }
}

public struct EmptyStateView: View {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Presentation models (@Observable; no SwiftUI property-wrapper macros)

@MainActor
@Observable
public final class HomePresentation {
    public var profiles: [Profile] = []
    public var installations: [InstalledMinecraft] = []
    public var runtimes: [RuntimeInstallation] = []
    public var selectedProfileID: UUID?
    public var report: CompatibilityReport?
    public var statusMessage: String = "Ready"
    public var doctorPreview: String = ""

    public let services: HarborServiceBundle

    public init(services: HarborServiceBundle) {
        self.services = services
    }

    public var selectedProfile: Profile? {
        profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    public var selectedInstallation: InstalledMinecraft? {
        guard let profile = selectedProfile else { return nil }
        return installations.first { $0.id == profile.selectedInstallationID }
    }

    public var selectedRuntime: RuntimeInstallation? {
        runtimes.first
    }

    public func reload() async {
        profiles = (try? await services.metadata.loadProfiles()) ?? []
        installations = (try? await services.metadata.loadInstallations()) ?? []
        runtimes = (try? await services.metadata.loadRuntimeInstallations()) ?? []
        if selectedProfileID == nil {
            selectedProfileID = profiles.first?.id
        }
        await refreshCompatibility()
        statusMessage = "Loaded \(profiles.count) profile(s)"
    }

    public func refreshCompatibility() async {
        let gate = LaunchGateWorkflow(services: services)
        report = try? await gate.evaluate(
            profile: selectedProfile ?? Profile(name: "None"),
            installation: selectedInstallation,
            runtime: selectedRuntime
        )
    }

    public func runDoctor() async {
        let snapshot = (try? await DiagnosticsWorkflow(services: services).collect()) ?? DiagnosticsSnapshot()
        doctorPreview = snapshot.redactedSummary
        statusMessage = "Doctor completed with \(snapshot.findings.count) finding(s)"
    }

    public func launch() async {
        statusMessage = "Feasibility gate incomplete — launch path is not live yet"
    }
}

@MainActor
@Observable
public final class AccountsPresentation {
    public var accounts: [AccountRecord] = []
    public var statusMessage: String = "Store account ≠ Xbox game identity"
    public let services: HarborServiceBundle

    public init(services: HarborServiceBundle) {
        self.services = services
    }

    public func reload() async {
        accounts = (try? await services.metadata.loadAccounts()) ?? []
    }

    public func beginGoogleSignIn() async {
        statusMessage = "Play sign-in is blocked until the feasibility gate provides a tested auth contract"
    }
}

@MainActor
@Observable
public final class VersionsPresentation {
    public var versions: [MinecraftVersion] = []
    public var installations: [InstalledMinecraft] = []
    public var statusMessage: String = ""
    public let services: HarborServiceBundle

    public init(services: HarborServiceBundle) {
        self.services = services
    }

    public func reload() async {
        installations = (try? await services.metadata.loadInstallations()) ?? []
        if let store = services.store {
            versions = (try? await store.listKnownVersions()) ?? []
        } else {
            versions = []
        }
        statusMessage = "Known=\(versions.count) Installed=\(installations.count)"
    }
}

@MainActor
@Observable
public final class ProfilesPresentation {
    public var profiles: [Profile] = []
    public var statusMessage: String = ""
    public var newName: String = "Default"
    public let services: HarborServiceBundle
    private let workflow: ProfileWorkflow

    public init(services: HarborServiceBundle) {
        self.services = services
        self.workflow = ProfileWorkflow(services: services)
    }

    public func reload() async {
        profiles = (try? await services.metadata.loadProfiles()) ?? []
    }

    public func createProfile() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusMessage = "Profile name is required"
            return
        }
        do {
            _ = try await workflow.create(name: name, installationID: nil, runtimeReleaseID: nil)
            await reload()
            statusMessage = "Created profile “\(name)” with isolated game data"
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

@MainActor
@Observable
public final class DiagnosticsPresentation {
    public var snapshot: DiagnosticsSnapshot?
    public var findings: [DoctorFinding] = []
    public var statusMessage: String = ""
    public let services: HarborServiceBundle

    public init(services: HarborServiceBundle) {
        self.services = services
    }

    public func collect() async {
        do {
            let value = try await DiagnosticsWorkflow(services: services).collect()
            snapshot = value
            findings = value.findings
            statusMessage = "Collected \(value.findings.count) findings"
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

@MainActor
@Observable
public final class HarborRootModel {
    public enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
        case home = "Home"
        case versions = "Versions"
        case profiles = "Profiles"
        case worlds = "Worlds"
        case diagnostics = "Diagnostics"
        case accounts = "Accounts"
        case settings = "Settings"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .home: return "house"
            case .versions: return "shippingbox"
            case .profiles: return "person.2"
            case .worlds: return "globe"
            case .diagnostics: return "stethoscope"
            case .accounts: return "person.crop.circle"
            case .settings: return "gearshape"
            }
        }
    }

    public var selection: SidebarItem = .home
    public var home: HomePresentation
    public var accounts: AccountsPresentation
    public var versions: VersionsPresentation
    public var profiles: ProfilesPresentation
    public var diagnostics: DiagnosticsPresentation

    public init(services: HarborServiceBundle) {
        self.home = HomePresentation(services: services)
        self.accounts = AccountsPresentation(services: services)
        self.versions = VersionsPresentation(services: services)
        self.profiles = ProfilesPresentation(services: services)
        self.diagnostics = DiagnosticsPresentation(services: services)
    }
}

// MARK: - Screens

public struct HomeView: View {
    public let model: HomePresentation

    public init(model: HomePresentation) {
        self.model = model
    }

    public var body: some View {
        List {
            Section("Session") {
                LabeledContent("Profile", value: model.selectedProfile?.name ?? "None")
                LabeledContent(
                    "Game version",
                    value: model.selectedInstallation.map { "\($0.originalVersionName) (\($0.buildID.abi.rawValue))" } ?? "Not installed"
                )
                LabeledContent(
                    "Runtime",
                    value: model.selectedRuntime.map { "\($0.releaseID) [\($0.health.rawValue)]" } ?? "Not installed"
                )
            }

            Section("Compatibility") {
                if let report = model.report {
                    HStack {
                        Text(report.overall.rawValue.capitalized)
                        StatusBadge(
                            report.launchBlocked ? "Launch blocked" : "Launch not blocked",
                            tone: report.launchBlocked ? .critical : .ok
                        )
                    }
                    Text("Ruleset \(report.rulesetRevision)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(report.capabilities) { capability in
                        HStack {
                            Text(capability.group.rawValue)
                            Spacer()
                            StatusBadge(capability.status.rawValue, tone: tone(for: capability.status))
                        }
                    }
                    ForEach(report.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("No compatibility report yet.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Actions") {
                Button("Reload") {
                    Task { await model.reload() }
                }
                Button("Launch") {
                    Task { await model.launch() }
                }
                Button("Run Doctor") {
                    Task { await model.runDoctor() }
                }
            }

            if !model.doctorPreview.isEmpty {
                Section("Doctor preview (redacted)") {
                    Text(model.doctorPreview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("BedrockHarbor")
        .task { await model.reload() }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
    }

    private func tone(for status: CompatibilityStatus) -> StatusBadge.Tone {
        switch status {
        case .compatible: return .ok
        case .partiallyCompatible: return .warning
        case .unknown: return .neutral
        case .unsupported: return .critical
        }
    }
}

public struct AccountsView: View {
    public let model: AccountsPresentation

    public init(model: AccountsPresentation) {
        self.model = model
    }

    public var body: some View {
        List {
            Section("Concepts") {
                Text("Store account authorizes Minecraft acquisition via Google Play. Game identity (Xbox/Microsoft) is separate and is not implied by store sign-in.")
                    .font(.callout)
            }
            Section("Accounts") {
                if model.accounts.isEmpty {
                    Text("No store accounts yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.accounts) { account in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.accountLabel)
                            Text(account.sessionState.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Sign in with Google Play") {
                    Task { await model.beginGoogleSignIn() }
                }
            }
        }
        .navigationTitle("Accounts")
        .task { await model.reload() }
        .safeAreaInset(edge: .bottom) {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.bar)
        }
    }
}

public struct VersionsView: View {
    public let model: VersionsPresentation

    public init(model: VersionsPresentation) {
        self.model = model
    }

    public var body: some View {
        List {
            Section("Installed") {
                if model.installations.isEmpty {
                    EmptyStateView(
                        title: "No installations",
                        message: "Installs require entitlement + delivery resolution after the feasibility gate."
                    )
                } else {
                    ForEach(model.installations) { item in
                        VStack(alignment: .leading) {
                            Text(item.originalVersionName)
                            Text(item.buildID.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Catalog") {
                ForEach(model.versions) { version in
                    VStack(alignment: .leading) {
                        Text(version.displayName)
                        Text("\(version.availability.rawValue) · \(version.provenance.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Versions")
        .task { await model.reload() }
        .safeAreaInset(edge: .bottom) {
            Text(model.statusMessage)
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }
}

public struct ProfilesView: View {
    public let model: ProfilesPresentation

    public init(model: ProfilesPresentation) {
        self.model = model
    }

    public var body: some View {
        List {
            Section("Profiles") {
                if model.profiles.isEmpty {
                    Text("Each profile gets its own game data root.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.profiles) { profile in
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            Text("data-root \(profile.dataRootID)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Create") {
                TextField(
                    "Profile name",
                    text: Binding(
                        get: { model.newName },
                        set: { model.newName = $0 }
                    )
                )
                Button("Create isolated profile") {
                    Task { await model.createProfile() }
                }
            }
        }
        .navigationTitle("Profiles")
        .task { await model.reload() }
        .safeAreaInset(edge: .bottom) {
            Text(model.statusMessage)
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }
}

public struct WorldsView: View {
    public init() {}

    public var body: some View {
        EmptyStateView(
            title: "Worlds",
            message: "World discovery is read-only and appears after profiles have game data. Backups require the game to be stopped and the data-root lease held."
        )
        .navigationTitle("Worlds")
    }
}

public struct DiagnosticsView: View {
    public let model: DiagnosticsPresentation

    public init(model: DiagnosticsPresentation) {
        self.model = model
    }

    public var body: some View {
        List {
            Section("Doctor") {
                Button("Collect findings") {
                    Task { await model.collect() }
                }
                if let snapshot = model.snapshot {
                    Text(snapshot.redactedSummary)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            Section("Findings") {
                ForEach(model.findings) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(finding.title)
                            Spacer()
                            StatusBadge(finding.severity.rawValue, tone: tone(finding.severity))
                        }
                        Text(finding.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Export") {
                Text("Diagnostic export previews redacted content before saving. Uploads are never automatic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Diagnostics")
        .safeAreaInset(edge: .bottom) {
            Text(model.statusMessage)
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    private func tone(_ severity: DoctorFinding.Severity) -> StatusBadge.Tone {
        switch severity {
        case .ok: return .ok
        case .warning: return .warning
        case .critical: return .critical
        case .unknown: return .neutral
        }
    }
}

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        Form {
            Section("About") {
                LabeledContent("Application", value: "BedrockHarbor")
                LabeledContent("License", value: "Apache-2.0")
                LabeledContent("Target", value: "macOS 14+, Apple Silicon")
            }
            Section("Unofficial project") {
                Text("BedrockHarbor is an unofficial project and is not affiliated with Mojang, Microsoft, or Google.")
                    .font(.footnote)
            }
            Section("Security") {
                Text("Credentials stay in the macOS login Keychain. Secrets are excluded from metadata, logs, and diagnostic exports by default.")
                    .font(.footnote)
            }
            Section("Updates") {
                Text("Sparkle will update BedrockHarbor only. Runtime artifacts are managed separately from approved upstream sources.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .formStyle(.grouped)
    }
}

// MARK: - Root split view

public struct HarborRootView: View {
    public let model: HarborRootModel

    public init(services: HarborServiceBundle) {
        self.model = HarborRootModel(services: services)
    }

    public init(model: HarborRootModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(HarborRootModel.SidebarItem.allCases, selection: Binding(
                get: { model.selection },
                set: { if let value = $0 { model.selection = value } }
            )) { item in
                Label(item.rawValue, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch model.selection {
            case .home:
                HomeView(model: model.home)
            case .versions:
                VersionsView(model: model.versions)
            case .profiles:
                ProfilesView(model: model.profiles)
            case .worlds:
                WorldsView()
            case .diagnostics:
                DiagnosticsView(model: model.diagnostics)
            case .accounts:
                AccountsView(model: model.accounts)
            case .settings:
                SettingsView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
