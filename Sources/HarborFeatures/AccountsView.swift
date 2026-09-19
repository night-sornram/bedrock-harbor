import SwiftUI

// MARK: - Accounts

/// Google Play identity + sign-in actions, plus the Microsoft-in-Minecraft
/// guidance (Task 8) for the in-game Xbox sign-in.
public struct AccountsView: View {
    public let app: AppState
    public let onRecovery: (OperationTracker.Recovery) -> Void
    public init(app: AppState, onRecovery: @escaping (OperationTracker.Recovery) -> Void) {
        self.app = app
        self.onRecovery = onRecovery
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                googlePlay

                OperationPhaseView(tracker: app.accountOperations, onRecovery: onRecovery)

                microsoftHelp
            }
            .padding(24)
        }
        .navigationTitle("Accounts")
        .task { await app.reload() }
    }

    private var googlePlay: some View {
        GroupBox("Google Play") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent(
                    "Identity",
                    value: app.isPlaySignedIn
                        ? (app.playAccountLabel.isEmpty ? "Google Play" : app.playAccountLabel)
                        : "Not signed in"
                )
                if app.isPlaySignedIn {
                    Label("Downloads ready — the Play client can fetch Minecraft", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Sign-in is only needed to download from Google Play. A Minecraft package already on this Mac plays without it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await app.googleSignIn() }
                    } label: {
                        HStack {
                            if app.signInBusy { ProgressView().controlSize(.small) }
                            Image(systemName: "person.crop.circle")
                            Text("Sign in")
                        }
                    }
                    .disabled(app.signInBusy)

                    Button("Sign in (fresh)") {
                        Task { await app.googleSignIn(fresh: true) }
                    }
                    .disabled(app.signInBusy)
                }
            }
            .padding(4)
        }
    }

    /// Task 8 guidance: what to do when the in-game Microsoft sign-in stalls
    /// on a passkey challenge the embedded webview cannot open.
    private var microsoftHelp: some View {
        GroupBox("Microsoft sign-in inside Minecraft") {
            Text("""
            If the in-game Microsoft sign-in gets stuck on "Face, fingerprint, PIN or security key": \
            Microsoft sometimes challenges embedded login windows with a passkey the window cannot open \
            (known upstream limitation, minecraft-linux issue #1523) — your account is fine.\n\n\
            Sign in with your password or PIN when offered, use "Use my password instead" or the other \
            verification links in the challenge, or complete sign-in on another device where the \
            challenge is available.\n\n\
            If sign-in still fails: check Diagnostics → Doctor and the session log for \
            mcpelauncher-webview errors. Llama error 0x80070057 means the helper's resources \
            are broken — Settings → Reinstall runtime.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(4)
        }
    }
}
