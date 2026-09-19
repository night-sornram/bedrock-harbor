import AppKit
import Foundation
import HarborApplication
import HarborFeatures
import HarborPlatform
import HarborRuntime
import SwiftUI

@MainActor
@Observable
final class AppBootstrap {
    static let shared = AppBootstrap()
    var services: HarborServiceBundle?
    var startupError: String?
    var bootstrapNote: String = ""
    private var didStart = false

    func ensureStarted() {
        guard !didStart else { return }
        didStart = true
        do {
            let paths = try HarborPaths.live()
            let timing = LaunchTimingRecorder(directory: paths.metadataDirectory)
            let launcher = ProcessLaunchSupervisor(paths: paths)
            let bundle = try CompositionRoot.makeFoundationBundle(
                paths: paths,
                runtimeProvider: LocalRuntimeProvider(),
                runtimeLauncher: launcher
            )
            services = bundle
            Task {
                await timing.begin(kind: "appStart")
                await timing.mark(.appLaunch)
                do {
                    bootstrapNote = try await LocalLaunchBootstrap.prepareIfNeeded(
                        services: bundle,
                        launcher: launcher,
                        timing: timing
                    )
                    // The appStart session is otherwise never ended — close it
                    // now (kind-guarded: a game launch that started during
                    // bootstrap owns the recorder by now and must not be cut).
                    await timing.end(kind: "appStart", outcome: "ok")
                } catch {
                    bootstrapNote = error.localizedDescription
                    await timing.end(kind: "appStart", outcome: "failed")
                }
                // The UI's first metadata read races this bootstrap (it can download
                // the runtime for ~40 s) — tell it to re-read state now that the
                // writes are done, or the Home screen can sit on the Install step
                // for an already-installed game.
                NotificationCenter.default.post(name: .harborBootstrapFinished, object: nil)
            }
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }

    func retry() {
        didStart = false
        ensureStarted()
    }
}

@main
struct BedrockHarborApp: App {
    var body: some Scene {
        WindowGroup("BedrockHarbor") {
            RootHost(bootstrap: AppBootstrap.shared)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About BedrockHarbor") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
        }
    }
}

struct RootHost: View {
    let bootstrap: AppBootstrap
    var body: some View {
        Group {
            if let services = bootstrap.services {
                HarborRootView(services: services)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(bootstrap.startupError ?? "Preparing Harbor…").foregroundStyle(.secondary)
                    if bootstrap.startupError != nil {
                        Button("Retry") { bootstrap.retry() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { bootstrap.ensureStarted() }
        .safeAreaInset(edge: .bottom) {
            if !bootstrap.bootstrapNote.isEmpty {
                Text(bootstrap.bootstrapNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.bar)
            }
        }
    }
}
