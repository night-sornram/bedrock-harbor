import SwiftUI

// MARK: - Play

/// The landing screen: selected profile + game version + readiness summary,
/// ONE prominent Play button, live launch progress with named stages and
/// elapsed seconds, Stop/Cancel, and short failures with recovery actions.
/// First-run users land here — the embedded readiness checklist replaces the
/// old onboarding wall, and it reads snapshots only (no implicit scans).
public struct PlayView: View {
    public let app: AppState
    public let onRecovery: (OperationTracker.Recovery) -> Void
    public init(app: AppState, onRecovery: @escaping (OperationTracker.Recovery) -> Void) {
        self.app = app
        self.onRecovery = onRecovery
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                readinessChecklist

                launchControls

                if app.launchProgress.stage != nil {
                    launchProgressCard
                }

                OperationPhaseView(tracker: app.playOperations, onRecovery: onRecovery)

                if let pct = app.downloadProgress {
                    DownloadProgressCard(
                        label: app.downloadLabel.isEmpty ? "Minecraft" : app.downloadLabel,
                        progress: pct,
                        detail: app.downloadDetail
                    )
                }

                details
            }
            .padding(24)
        }
        .navigationTitle("Play")
        .task { await app.reload() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.selectedProfile?.name ?? "No profile")
                        .font(.title2.bold())
                    Text(gameVersionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                readinessPill
            }
        }
    }

    private var gameVersionText: String {
        if let install = app.gameInstallation {
            return "Minecraft \(install.originalVersionName) · runtime \(app.runtime?.releaseID ?? "none")"
        }
        return "Minecraft not installed · runtime \(app.runtime?.releaseID ?? "none")"
    }

    private var readinessPill: some View {
        switch app.nextStep {
        case 1:
            return StatusPill("Sign-in suggested", tone: .neutral)
        case 2:
            return StatusPill("Install Minecraft", tone: .warn)
        default:
            return app.isGameRunning || app.launchInFlight
                ? StatusPill(app.isGameRunning ? "Running" : "Launching", tone: .ok)
                : StatusPill("Ready to launch", tone: .ok)
        }
    }

    /// First-run readiness checklist — snapshots only. Sign-in is optional
    /// whenever the game is already on this Mac.
    private var readinessChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                subtitle: "Harbor downloads it from Google Play, or imports a package you own",
                done: app.hasVerifiedGame,
                active: app.nextStep == 2
            )
            StepRow(
                n: 3,
                title: "Launch",
                subtitle: "Start the game with the profile above",
                done: app.isGameRunning,
                active: app.nextStep == 3
            )

            if !app.isPlaySignedIn && !app.hasVerifiedGame {
                Button("Using a local APK? Skip Play sign-in") {
                    app.useLocalAPK()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var launchControls: some View {
        HStack(spacing: 12) {
            Button {
                Task { await app.launchGame() }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.launchInFlight || app.isInstalling)

            if app.isGameRunning {
                Button {
                    Task { await app.stopGame() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .accessibilityLabel("Stop Minecraft")
            } else if app.canCancelLaunchPreparation {
                // Strictly during preparation: once Stop is pressed the
                // reservation is held until the terminal event, and Cancel
                // must not reappear (or clobber the "Stopping" label).
                Button("Cancel") {
                    Task { await app.requestCancelLaunch() }
                }
                .accessibilityLabel("Cancel launch preparation")
            }
        }
    }

    /// Named stage + elapsed seconds (monotonic clock, 1 Hz text update — no
    /// custom animation). Percentages are never faked here; they stay on the
    /// download card.
    private var launchProgressCard: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(app.launchProgress.stage?.label ?? "")
                .font(.callout.weight(.medium))
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let seconds = app.launchProgress.elapsedSeconds() {
                    Text(LaunchProgressTracker.formatElapsed(seconds))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        GroupBox("Details") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Profile", value: app.selectedProfile?.name ?? "—")
                LabeledContent("Runtime", value: app.runtime.map { "\($0.releaseID) [\($0.health.rawValue)]" } ?? "—")
                LabeledContent("Game", value: app.gameInstallation.map { "\($0.originalVersionName) [\($0.integrity.rawValue)]" } ?? "Not installed")
            }
            .padding(4)
        }
    }
}
