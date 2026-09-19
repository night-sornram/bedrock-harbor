import Foundation
import HarborDomain
import HarborPlatform

/// Installs the mcpelauncher runtime (the "Minecraft Bedrock Launcher" app from
/// minecraft-linux/macos-builder) into BedrockHarbor/Runtimes so Harbor never asks
/// the user to run Scripts/install_local_runtime.sh by hand.
/// Layout contract mirrors that script and LocalRuntimeDiscovery's expectations.
public enum HarborRuntimeInstaller {
    public static let versionLabel = "v1.8.4-573"
    public static let sourceURL = URL(
        string: "https://github.com/minecraft-linux/macos-builder/releases/download/\(versionLabel)/Minecraft.Bedrock.Launcher.dmg"
    )!
    public static let installDirectoryName = "harbor-mcpelauncher-\(versionLabel)"

    public static func runtimePresent() -> Bool {
        !LocalRuntimeDiscovery.harborRuntimeRoots().isEmpty
    }

    /// Ensure a usable runtime exists under BedrockHarbor/Runtimes.
    /// Returns true when this call installed it; false when it already existed.
    @discardableResult
    public static func ensureInstalled(status: (@Sendable (String) -> Void)? = nil) async throws -> Bool {
        if runtimePresent() { return false }
        return try await InstallSingleFlight.shared.install(status: status)
    }

    /// Download the launcher DMG (reusing a previously completed download) and
    /// deploy its app bundle contents into the Harbor runtime root.
    public static func install(status: (@Sendable (String) -> Void)? = nil) async throws {
        let fm = FileManager.default
        let downloads = LocalRuntimeDiscovery.harborSupport
            .appendingPathComponent("Runtimes/_downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let dmg = downloads.appendingPathComponent("Minecraft.Bedrock.Launcher.dmg")

        if !fm.fileExists(atPath: dmg.path) {
            try await downloadDMG(to: dmg, status: status)
        }
        do {
            status?("Finishing Minecraft Bedrock Launcher install…")
            try await deploy(from: dmg)
        } catch {
            // A stale or partially cached DMG is the likely cause — refetch once.
            status?("Retrying launcher install with a fresh download…")
            try? fm.removeItem(at: dmg)
            try await downloadDMG(to: dmg, status: status)
            try await deploy(from: dmg)
        }
    }

    // MARK: - Download

    private static func downloadDMG(to destination: URL, status: (@Sendable (String) -> Void)?) async throws {
        let delegate = LauncherDownloadProgress(report: status)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (tmpURL, response) = try await session.download(from: sourceURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw HarborError.providerFailure(reason: "launcher download failed — HTTP \(http.statusCode)")
            }
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: tmpURL, to: destination)
        } catch let error as HarborError {
            throw error
        } catch {
            throw HarborError.providerFailure(reason: "launcher download failed: \(error.localizedDescription)")
        }
    }

    private final class LauncherDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let report: (@Sendable (String) -> Void)?
        private var lastReportAt = Date.distantPast

        init(report: (@Sendable (String) -> Void)?) {
            self.report = report
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite totalBytesExpected: Int64
        ) {
            guard totalBytesExpected > 0, let report else { return }
            let now = Date()
            guard now.timeIntervalSince(lastReportAt) >= 0.7 else { return }
            lastReportAt = now
            let percent = min(Int(Double(totalBytesWritten) / Double(totalBytesExpected) * 100), 100)
            report("Downloading Minecraft Bedrock Launcher — \(percent)%")
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The async download(from:) call hands this file to its caller; nothing to move here.
        }
    }

    // MARK: - Mount + deploy

    /// Mount the DMG read-only and deploy the launcher app it contains.
    /// Async: hdiutil runs through `HarborSubprocess`, and the mount is always
    /// detached before returning (the old `defer` pattern spelled out as
    /// do/catch + success-path cleanup, since awaits cannot live in a defer).
    public static func deploy(from dmg: URL) async throws {
        let fm = FileManager.default
        // Unique mount dir per deploy + guaranteed detach: a leaked mount at a fixed
        // path both breaks the next attach ("mountpoint busy") and lingers as a
        // visible "Minecraft Bedrock Launcher" volume on the user's Mac.
        let mountPoint = dmg.deletingLastPathComponent()
            .appendingPathComponent("mnt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        var mounted = false
        do {
            do {
                try await runTool("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path])
                mounted = true
            } catch {
                // Attach failed; hdiutil may still have mounted partially — try once.
                await detachMount(at: mountPoint)
                throw error
            }
            let contents = mountPoint.appendingPathComponent("Minecraft Bedrock Launcher.app/Contents", isDirectory: true)
            guard fm.fileExists(atPath: contents.path) else {
                throw HarborError.invalidPackage(reason: "Minecraft Bedrock Launcher.app missing inside DMG")
            }
            let destination = LocalRuntimeDiscovery.harborSupport
                .appendingPathComponent("Runtimes/\(installDirectoryName)", isDirectory: true)
            try deploy(appContents: contents, destination: destination)
        } catch {
            // Was the old `defer { if mounted { detach; detach -force } }`.
            await detachOnExit(of: mountPoint, mounted: mounted)
            try? fm.removeItem(at: mountPoint)
            throw error
        }
        await detachOnExit(of: mountPoint, mounted: mounted)
        try? fm.removeItem(at: mountPoint)
    }

    /// Best-effort unmount used by `deploy` on every exit path (plain detach,
    /// then a forced one when the volume had mounted successfully).
    private static func detachOnExit(of mountPoint: URL, mounted: Bool) async {
        if mounted {
            await detachMount(at: mountPoint)
            await detachMount(at: mountPoint, force: true)
        }
    }

    /// Fire-and-forget hdiutil detach; failures are ignored like before.
    private static func detachMount(at mountPoint: URL, force: Bool = false) async {
        _ = try? await runTool(
            "/usr/bin/hdiutil",
            force ? ["detach", "-force", mountPoint.path] : ["detach", mountPoint.path]
        )
    }

    /// Human-readable names of the Microsoft sign-in helper resources missing
    /// from a runtime root. The helper (`mcpelauncher-webview`) needs its
    /// executable, the Qt cocoa platform plugin, the executable-side qt.conf,
    /// and the QML modules under `Resources/qml` (QtQuick for the helper UI,
    /// QtWebEngine for both the webview module and the WebEngine core
    /// resources, which ship under the same tree in the pinned DMG). Empty
    /// means the helper has everything it needs to start.
    public static func validateHelperResources(root: URL) -> [String] {
        let fm = FileManager.default
        var missing: [String] = []
        if !fm.isExecutableFile(atPath: root.appendingPathComponent("MacOS/mcpelauncher-webview").path) {
            missing.append("Microsoft sign-in helper (MacOS/mcpelauncher-webview)")
        }
        if !fm.fileExists(atPath: root.appendingPathComponent("PlugIns/platforms/libqcocoa.dylib").path) {
            missing.append("Qt platform plugin (PlugIns/platforms/libqcocoa.dylib)")
        }
        if !fm.fileExists(atPath: root.appendingPathComponent("MacOS/qt.conf").path) {
            missing.append("Qt configuration (MacOS/qt.conf)")
        }
        for (name, path) in [
            ("QtQuick modules (Resources/qml/QtQuick)", "Resources/qml/QtQuick"),
            ("QtWebEngine modules (Resources/qml/QtWebEngine)", "Resources/qml/QtWebEngine"),
        ] where !isDirectoryPresent(root.appendingPathComponent(path, isDirectory: true)) {
            missing.append(name)
        }
        return missing
    }

    /// True when `url` exists and is a directory (a stray file must not pass as
    /// a QML module directory).
    private static func isDirectoryPresent(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Pure file layout step: copy app bundle contents into a runtime root and
    /// write the runtime.json manifest LocalRuntimeDiscovery reads.
    public static func deploy(appContents: URL, destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appContents.appendingPathComponent("MacOS").path) else {
            throw HarborError.invalidPackage(reason: "Not a macOS app bundle: \(appContents.path)")
        }
        // Without the Qt platform plugins the Xbox sign-in webview crashes at
        // startup (in-game: login error Llama 0x80070057) — refuse plugin-less bundles.
        guard fm.fileExists(atPath: appContents.appendingPathComponent("PlugIns/platforms/libqcocoa.dylib").path) else {
            throw HarborError.invalidPackage(reason: "Launcher bundle is missing Qt platform plugins: \(appContents.path)")
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(
            at: destination.appendingPathComponent("share", isDirectory: true),
            withIntermediateDirectories: true
        )
        for dir in ["MacOS", "Resources", "Frameworks", "PlugIns"] {
            try fm.copyItem(
                at: appContents.appendingPathComponent(dir, isDirectory: true),
                to: destination.appendingPathComponent(dir, isDirectory: true)
            )
        }
        // mcpelauncher-webview (Microsoft sign-in) runs outside a real app bundle and
        // then never applies Resources/qt.conf to its QML import path — it dies with
        // "module QtQuick.Controls is not installed" (in-game: Llama 0x80070057).
        // A qt.conf next to the executable with the prefix pinned to the runtime root
        // restores the same paths the bundle layout would give.
        try "[Paths]\nPrefix = ..\nPlugins = PlugIns\nImports = Resources/qml\nQmlImports = Resources/qml\n".write(
            to: destination.appendingPathComponent("MacOS/qt.conf"),
            atomically: true,
            encoding: .utf8
        )
        // The engine DMG may arrive via a browser download, and its files then carry
        // com.apple.quarantine — Gatekeeper uses that to block mcpelauncher-webview's
        // plugins at Microsoft sign-in ("Apple could not verify…"), so strip it.
        stripQuarantine(at: destination)
        // gamecontrollerdb + preload libs live next to the runtime root under share/.
        let sharedRuntime = destination.appendingPathComponent("Resources/mcpelauncher", isDirectory: true)
        if fm.fileExists(atPath: sharedRuntime.path) {
            try fm.copyItem(
                at: sharedRuntime,
                to: destination.appendingPathComponent("share/mcpelauncher", isDirectory: true)
            )
        }
        let manifest: [String: String] = [
            "version": versionLabel,
            "source": "minecraft-linux/macos-builder",
            "sourceURL": sourceURL.absoluteString,
            "deployedBy": "BedrockHarbor isolated install",
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination.appendingPathComponent("runtime.json"), options: .atomic)

        guard fm.isExecutableFile(atPath: destination.appendingPathComponent("MacOS/mcpelauncher-client").path) else {
            throw HarborError.invalidPackage(reason: "mcpelauncher-client missing after launcher install")
        }
        // Same helper-resource gate the pre-launch readiness check runs: a
        // deployed runtime whose Microsoft sign-in helper cannot start must be
        // rejected at install time, not surface in-game as Llama 0x80070057.
        let missingHelperResources = validateHelperResources(root: destination)
        if !missingHelperResources.isEmpty {
            throw HarborError.invalidPackage(
                reason: "Launcher bundle is missing Microsoft sign-in resources: \(missingHelperResources.joined(separator: ", "))"
            )
        }
    }

    /// Best-effort recursive removal of com.apple.quarantine — copyItem preserves
    /// the attribute, and Gatekeeper blocks quarantined plugins at load time.
    private static func stripQuarantine(at root: URL) {
        var paths = [root.path]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL { paths.append(url.path) }
        }
        for path in paths {
            removexattr(path, "com.apple.quarantine", 0)
        }
    }

    /// Runs a helper tool through the bounded async runner; throws with the
    /// (capped) stderr on failure. No blocking waits on cooperative threads.
    @discardableResult
    private static func runTool(_ launchPath: String, _ arguments: [String]) async throws -> String {
        let result = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: launchPath),
            arguments: arguments
        )
        guard result.exitCode == 0, !result.timedOut else {
            throw HarborError.unsupportedRuntime(
                reason: "\(URL(fileURLWithPath: launchPath).lastPathComponent) failed: \(result.stderr)"
            )
        }
        return result.stdout
    }

    /// One install at a time per process — startup self-heal and a user-triggered
    /// install must not race each other over the same destination directory.
    private actor InstallSingleFlight {
        static let shared = InstallSingleFlight()
        private var inFlight: Task<Void, Error>?

        func install(status: (@Sendable (String) -> Void)?) async throws -> Bool {
            if HarborRuntimeInstaller.runtimePresent() { return false }
            let started = inFlight ?? Task { try await HarborRuntimeInstaller.install(status: status) }
            inFlight = started
            defer { inFlight = nil }
            do {
                try await started.value
            } catch {
                throw error
            }
            guard HarborRuntimeInstaller.runtimePresent() else {
                throw HarborError.unsupportedRuntime(
                    reason: "Minecraft Bedrock Launcher did not install correctly — check the network and try again"
                )
            }
            return true
        }
    }
}
