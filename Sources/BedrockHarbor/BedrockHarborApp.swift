import AppKit
import Foundation
import HarborApplication
import HarborFeatures
import HarborPlatform
import SwiftUI

@MainActor
@Observable
final class AppBootstrap {
    static let shared = AppBootstrap()

    var services: HarborServiceBundle?
    var startupError: String?
    private var didStart = false

    func ensureStarted() {
        guard !didStart else { return }
        didStart = true
        do {
            services = try CompositionRoot.makeFoundationBundle()
            startupError = nil
        } catch {
            startupError = error.localizedDescription
            services = nil
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
                Button("About BedrockHarbor") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandMenu("Harbor") {
                Button("Open Application Support") {
                    if let url = try? HarborPaths.live().applicationSupportRoot {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Open Session Logs") {
                    if let url = try? HarborPaths.live().sessionLogs {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

/// Host view that avoids SwiftUI property-wrapper macros unavailable under CommandLineTools SPM builds.
struct RootHost: View {
    let bootstrap: AppBootstrap

    var body: some View {
        Group {
            if let services = bootstrap.services {
                HarborRootView(services: services)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(bootstrap.startupError ?? "Preparing Harbor…")
                        .foregroundStyle(.secondary)
                    if bootstrap.startupError != nil {
                        Button("Retry") { bootstrap.retry() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { bootstrap.ensureStarted() }
    }
}
