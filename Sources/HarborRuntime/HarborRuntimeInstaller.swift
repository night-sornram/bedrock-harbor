import Foundation
import HarborDomain

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
            try deploy(from: dmg)
        } catch {
            // A stale or partially cached DMG is the likely cause — refetch once.
            status?("Retrying launcher install with a fresh download…")
            try? fm.removeItem(at: dmg)
            try await downloadDMG(to: dmg, status: status)
            try deploy(from: dmg)
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
    public static func deploy(from dmg: URL) throws {
        let fm = FileManager.default
        let mountPoint = dmg.deletingLastPathComponent().appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try runTool("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path])
        var mounted = true
        defer {
            if mounted { try? runTool("/usr/bin/hdiutil", ["detach", mountPoint.path]) }
        }
        let contents = mountPoint.appendingPathComponent("Minecraft Bedrock Launcher.app/Contents", isDirectory: true)
        guard fm.fileExists(atPath: contents.path) else {
            throw HarborError.invalidPackage(reason: "Minecraft Bedrock Launcher.app missing inside DMG")
        }
        let destination = LocalRuntimeDiscovery.harborSupport
            .appendingPathComponent("Runtimes/\(installDirectoryName)", isDirectory: true)
        try deploy(appContents: contents, destination: destination)
        mounted = false
        try runTool("/usr/bin/hdiutil", ["detach", mountPoint.path])
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
    }

    @discardableResult
    private static func runTool(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw HarborError.unsupportedRuntime(
                reason: "\(URL(fileURLWithPath: launchPath).lastPathComponent) failed: \(errText)"
            )
        }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
