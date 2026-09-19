import SwiftUI

// MARK: - Settings

/// Setup (run setup again), runtime maintenance (reinstall runtime with
/// progress, refresh compatibility patches), and the About/credits sections.
public struct SettingsView: View {
    public let app: AppState
    public let onRecovery: (OperationTracker.Recovery) -> Void
    public init(app: AppState, onRecovery: @escaping (OperationTracker.Recovery) -> Void) {
        self.app = app
        self.onRecovery = onRecovery
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                setup

                runtimeMaintenance

                OperationPhaseView(tracker: app.maintenanceOperations, onRecovery: onRecovery)

                if let pct = app.downloadProgress {
                    DownloadProgressCard(
                        label: app.downloadLabel.isEmpty ? "Minecraft Bedrock Launcher" : app.downloadLabel,
                        progress: pct,
                        detail: app.downloadDetail
                    )
                }

                about
                credits
            }
            .padding(24)
        }
        .navigationTitle("Settings")
        .task { await app.reload() }
    }

    private var setup: some View {
        GroupBox("Setup") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(
                    "Current runtime",
                    value: app.runtime?.releaseID ?? "none recorded"
                )
                Button("Run setup again") {
                    app.resetSetup()
                }
                Text("Resetting setup clears the local-package preference; the readiness checklist on Play then walks the steps again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private var runtimeMaintenance: some View {
        GroupBox("Runtime maintenance") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Reinstall runtime") {
                    Task { await app.reinstallRuntime() }
                }
                .disabled(app.isInstalling)

                Button("Refresh compatibility patches") {
                    Task { await app.refreshCompatibilityPatches() }
                }

                Text("""
                Reinstall downloads and deploys the official mcpelauncher runtime again — \
                the fix for a broken Microsoft sign-in helper (Llama 0x80070057) or a \
                runtime damaged after install. Patch refresh pulls the latest \
                mcpelauncher-updates compatibility catalog now instead of at next launch.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private var about: some View {
        GroupBox("About") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("App", value: "BedrockHarbor")
                LabeledContent("License", value: "Apache-2.0")
            }
            .padding(4)
        }
    }

    private var credits: some View {
        GroupBox("Credits") {
            Text(creditsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(4)
        }
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
