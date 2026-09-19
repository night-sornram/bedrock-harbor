import AppKit
import HarborApplication
import SwiftUI

// MARK: - Worlds

/// World ("map") management: every world under the active profile, export to
/// a standard `.mcworld` (opens on Windows/Android/iOS), and import from a
/// `.mcworld`/`.zip` file or an already-extracted world folder.
public struct WorldsView: View {
    public let app: AppState
    public let onRecovery: (OperationTracker.Recovery) -> Void
    public init(app: AppState, onRecovery: @escaping (OperationTracker.Recovery) -> Void) {
        self.app = app
        self.onRecovery = onRecovery
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                actions

                OperationPhaseView(tracker: app.worldsOperations, onRecovery: onRecovery)

                worldList
            }
            .padding(24)
        }
        .navigationTitle("Worlds")
        .task { await app.loadWorlds() }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                app.importWorldFromPanel()
            } label: {
                Label(
                    app.worldsOperations.isWorking ? "Working…" : "Import world…",
                    systemImage: "square.and.arrow.down"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.worldsOperations.isWorking)

            if app.isGameRunning {
                Label(
                    "Close Minecraft before importing or exporting — world files are locked while the game runs.",
                    systemImage: "lock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var worldList: some View {
        GroupBox("Worlds on this Mac") {
            if !app.hasProfileForWorlds {
                Text("No profile yet — sign in or launch the game once, then worlds appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else if app.worlds.isEmpty {
                Text("No worlds yet — create one in the game, or import a .mcworld file from another device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(app.worlds) { world in
                        worldRow(world)
                        if world.id != app.worlds.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func worldRow(_ world: MinecraftWorld) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "map")
                .foregroundStyle(Color.secondary)
                .accessibilityLabel("World")
            VStack(alignment: .leading, spacing: 3) {
                Text(world.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    if let modified = world.modifiedAt {
                        Text(modified, format: .relative(presentation: .named))
                    }
                    Text(world.formattedSize)
                    Text(world.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Export…") {
                app.exportWorld(world)
            }
            .disabled(app.worldsOperations.isWorking)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([world.directoryURL])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal world folder in Finder")
            .accessibilityLabel("Reveal \(world.name) in Finder")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}
