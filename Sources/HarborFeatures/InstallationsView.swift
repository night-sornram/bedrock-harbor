import HarborDomain
import SwiftUI

// MARK: - Installations

/// Installed versions (name, version, integrity, provider), Play download,
/// APK/folder import, and the explicit "Rescan packages" full scan.
public struct InstallationsView: View {
    public let app: AppState
    public let onRecovery: (OperationTracker.Recovery) -> Void
    public init(app: AppState, onRecovery: @escaping (OperationTracker.Recovery) -> Void) {
        self.app = app
        self.onRecovery = onRecovery
    }

    /// Records worth listing: metadata placeholders are not installations.
    private var visibleInstallations: [InstalledMinecraft] {
        app.installations.filter { $0.providerID.rawValue != "missing-game" }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                actions

                OperationPhaseView(tracker: app.installOperations, onRecovery: onRecovery)

                if let pct = app.downloadProgress {
                    DownloadProgressCard(
                        label: app.downloadLabel.isEmpty ? "Minecraft" : app.downloadLabel,
                        progress: pct,
                        detail: app.downloadDetail
                    )
                }

                installationList
            }
            .padding(24)
        }
        .navigationTitle("Installations")
        .task { await app.reload() }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await app.installGame() }
            } label: {
                Label(
                    app.isInstalling ? "Working…" : "Download from Google Play",
                    systemImage: "icloud.and.arrow.down"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.isInstalling)

            HStack(spacing: 12) {
                Button("Install from APK / folder…") { app.importAPK() }
                Button("Rescan packages") {
                    Task { await app.rescanPackages() }
                }
                .disabled(app.isInstalling)
                Button("Open Minecraft on Google Play") { app.openPlayStoreListing() }
                    .buttonStyle(.link)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var installationList: some View {
        GroupBox("Installed versions") {
            if visibleInstallations.isEmpty {
                Text("No Minecraft package on this Mac yet — download from Google Play, import an APK, or rescan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleInstallations) { installation in
                        installationRow(installation)
                        if installation.id != visibleInstallations.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func installationRow(_ installation: InstalledMinecraft) -> some View {
        let isSelected = app.selectedProfile?.selectedInstallationID == installation.id
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "square.and.arrow.down")
                .foregroundStyle(isSelected ? Color.green : Color.secondary)
                .accessibilityLabel(isSelected ? "Selected installation" : "Installation")
            VStack(alignment: .leading, spacing: 3) {
                Text("Minecraft \(installation.originalVersionName)")
                    .font(.headline)
                HStack(spacing: 8) {
                    StatusPill(integrityLabel(installation.integrity), tone: integrityTone(installation.integrity))
                    Text(installation.providerID.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(isSelected ? "In use" : "Use") {
                Task { await app.selectInstallation(installation) }
            }
            .disabled(isSelected)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func integrityLabel(_ integrity: InstallationIntegrity) -> String {
        switch integrity {
        case .verified: return "Verified"
        case .failed: return "Failed"
        case .pendingVerification: return "Unverified"
        case .unknown: return "Unknown"
        }
    }

    private func integrityTone(_ integrity: InstallationIntegrity) -> StatusPill.Tone {
        switch integrity {
        case .verified: return .ok
        case .failed: return .bad
        case .pendingVerification, .unknown: return .neutral
        }
    }
}
