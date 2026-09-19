import AppKit
import HarborDomain
import HarborPlatform
import HarborRuntime
import SwiftUI

// MARK: - Diagnostics

/// Runtime health (readiness pieces + runtime records), recent launch timings
/// (stage → ms from the recorder's JSONL), Doctor findings, and the redacted
/// diagnostics export.
public struct DiagnosticsView: View {
    public let app: AppState
    public let onRecovery: (OperationTracker.Recovery) -> Void
    public init(app: AppState, onRecovery: @escaping (OperationTracker.Recovery) -> Void) {
        self.app = app
        self.onRecovery = onRecovery
    }

    /// Missing Microsoft-helper resources for the current runtime root.
    /// Computed once per screen entry (five cheap stats) — not per render.
    @State private var missingRuntimePieces: [String] = []
    @State private var timings: [LaunchTimingRecord] = []

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                runtimeHealth

                launchTimings

                doctor

                OperationPhaseView(tracker: app.diagnosticsOperations, onRecovery: onRecovery)

                exportButton
            }
            .padding(24)
        }
        .navigationTitle("Diagnostics")
        .task {
            await app.reload()
            reloadLocalDiagnostics()
        }
    }

    private func reloadLocalDiagnostics() {
        if let root = app.runtime.map({ URL(fileURLWithPath: $0.relativeInstallPath, isDirectory: true) }) {
            missingRuntimePieces = RuntimeReadiness.missingPieces(runtimeRoot: root)
        } else {
            missingRuntimePieces = []
        }
        timings = app.loadLaunchTimings()
    }

    // MARK: Runtime health

    private var runtimeHealth: some View {
        GroupBox("Runtime health") {
            VStack(alignment: .leading, spacing: 8) {
                if app.runtimes.isEmpty {
                    Text("No launcher runtime recorded. Play will install one automatically, or use Settings → Reinstall runtime.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.runtimes) { runtime in
                        HStack {
                            Text(runtime.releaseID)
                            StatusPill(runtime.health.rawValue, tone: healthTone(runtime.health))
                            Spacer()
                        }
                    }
                    if missingRuntimePieces.isEmpty {
                        Label("Microsoft sign-in helper resources present", systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.green)
                    } else {
                        Label(
                            "Missing helper resources: \(missingRuntimePieces.joined(separator: ", "))",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                        Text("A launch with missing resources fails fast — fix it with Settings → Reinstall runtime.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }

    private func healthTone(_ health: RuntimeHealth) -> StatusPill.Tone {
        switch health {
        case .healthy, .unknown: return health == .healthy ? .ok : .neutral
        case .degraded: return .warn
        case .broken, .quarantined: return .bad
        }
    }

    // MARK: Launch timings

    private var launchTimings: some View {
        GroupBox("Recent launch timings") {
            if timings.isEmpty {
                Text("No launch timing sessions recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Newest first; the recorder keeps a bounded history.
                let recent = Array(timings.reversed().prefix(10))
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recent, id: \.id) { record in
                        timingRecord(record)
                    }
                }
            }
        }
    }

    private func timingRecord(_ record: LaunchTimingRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(record.kind)
                    .font(.headline)
                Text(record.startedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.startedAt, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                StatusPill(record.outcome ?? "open", tone: outcomeTone(record.outcome))
                Spacer()
            }
            if record.stageMarks.isEmpty {
                Text("No stage marks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // stage → ms, in recorded order (marks are chronological).
                ForEach(sortedStages(record.stageMarks), id: \.0) { stage, ms in
                    HStack {
                        Text(stage)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(ms.rounded())) ms")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Stage marks sorted by elapsed time — dict order is not chronological.
    private func sortedStages(_ marks: [String: Double]) -> [(String, Double)] {
        marks.sorted { $0.value < $1.value }
    }

    private func outcomeTone(_ outcome: String?) -> StatusPill.Tone {
        switch outcome {
        case "ok": return .ok
        case "failed": return .bad
        case "cancelled": return .warn
        default: return .neutral
        }
    }

    // MARK: Doctor + export

    private var doctor: some View {
        GroupBox("Doctor") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Run checks") {
                    Task {
                        await app.runDoctor()
                        reloadLocalDiagnostics()
                    }
                }
                ForEach(app.doctorFindings) { finding in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            StatusPill(finding.severity.rawValue, tone: severityTone(finding.severity))
                            Text(finding.title).font(.callout.weight(.medium))
                        }
                        Text(finding.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }

    private func severityTone(_ severity: DoctorFinding.Severity) -> StatusPill.Tone {
        switch severity {
        case .ok: return .ok
        case .warning: return .warn
        case .critical: return .bad
        case .unknown: return .neutral
        }
    }

    private var exportButton: some View {
        Button("Export redacted diagnostics…") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Choose a folder for the redacted diagnostics bundle"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let app = self.app
            Task {
                await app.exportDiagnostics(to: url)
                reloadLocalDiagnostics()
            }
        }
    }
}
