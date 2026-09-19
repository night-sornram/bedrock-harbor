import Foundation
import HarborDomain
import HarborGooglePlay
import HarborPlatform

@MainActor
final class LivePlaySessionBackend: PlaySessionBackend {
    private let metadata: any MetadataRepository
    private let clearBrowserCookies: @MainActor () async -> Void
    private let runCheck: @Sendable (URL, [String], URL) async throws -> SubprocessResult
    private let binary: @MainActor () -> URL?

    init(
        metadata: any MetadataRepository,
        clearBrowserCookies: @escaping @MainActor () async -> Void = { await GoogleSignInController.clearSavedCookies() },
        binary: @escaping @MainActor () -> URL? = { GPlayDLClient.locateBinary(named: "gplayver") },
        runCheck: @escaping @Sendable (URL, [String], URL) async throws -> SubprocessResult = {
            try await HarborSubprocess.run(executable: $0, arguments: $1, currentDirectory: $2,
                                           timeout: 30, outputLimit: 16_000)
        }
    ) {
        self.metadata = metadata
        self.clearBrowserCookies = clearBrowserCookies
        self.binary = binary
        self.runCheck = runCheck
    }

    private static let cliSessionFiles = ["playdl.conf", "token_cache.conf", "device.conf.state"]

    private func savedConfig() -> [String: String] {
        guard let text = try? String(contentsOf: GPlayDLClient.workDir.appendingPathComponent("playdl.conf"), encoding: .utf8) else { return [:] }
        return Self.parseConfig(text)
    }

    static func parseConfig(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return values
    }

    private func nonempty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    func hasSavedCredentials() -> Bool {
        let backup = PlayCredentialBackup.load()
        return nonempty(savedConfig()["user_token"]) != nil
            || nonempty(backup.master) != nil || nonempty(backup.oauth) != nil
            || HarborPlayTokenBridge.loadOAuthToken() != nil
            || nonempty(PlaySessionStore.load().cookies["oauth_token"]) != nil
    }

    func validate() async -> PlayValidationResult {
        guard let binary = binary() else {
            return .unavailable("Google Play helper is missing. Open the packaged BedrockHarbor app to check this session.")
        }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("HarborAuth-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let config = savedConfig()
            let backup = PlayCredentialBackup.load()
            let session = PlaySessionStore.load()
            let master = nonempty(config["user_token"]) ?? nonempty(backup.master)
            let oauth = HarborPlayTokenBridge.loadOAuthToken() ?? nonempty(session.cookies["oauth_token"]) ?? nonempty(backup.oauth)
            let email = (nonempty(config["user_token"]) != nil ? config["user_email"] : nil)
                ?? backup.email ?? session.accountEmail ?? HarborPlayTokenBridge.loadAccountEmail() ?? ""
            guard !email.contains("\n"), !email.contains("\r") else { return .rejected }
            var args = ["--device", "device.conf", "--auth-check", "--save-auth"]
            if let master {
                guard !master.contains("\n"), !master.contains("\r") else { return .rejected }
                try Self.writePrivate("user_email = \(email)\nuser_token = \(master)\n", to: scratch.appendingPathComponent("playdl.conf"))
            } else if let oauth {
                // The helper reads a private file. Authentication material is
                // never added to argv, logs, or environment variables here.
                try Self.writePrivate(oauth, to: scratch.appendingPathComponent("access-token"))
                args += ["--access-token-file", "access-token", "--email", email]
            } else {
                return .rejected
            }
            try Self.writePrivate("config.native_platforms = [\n    arm64-v8a\n]\n", to: scratch.appendingPathComponent("device.conf"))
            if fm.fileExists(atPath: GPlayDLClient.workDir.appendingPathComponent("device.conf.state").path) {
                try fm.copyItem(at: GPlayDLClient.workDir.appendingPathComponent("device.conf.state"),
                                to: scratch.appendingPathComponent("device.conf.state"))
            }
            try Task.checkCancellation()
            let result = try await runCheck(binary, args, scratch)
            try Task.checkCancellation()
            if result.exitCode == 3 { return .rejected }
            guard result.exitCode == 0, !result.timedOut,
                  result.stdout.split(separator: "\n").contains("authentication verified") else {
                return .unavailable("Could not verify the Google session. Check your connection and retry.")
            }
            // The helper writes only into its isolated directory. Commit only
            // after success, before any further suspension/cancellation point.
            let verifiedConfig = try String(contentsOf: scratch.appendingPathComponent("playdl.conf"), encoding: .utf8)
            let verifiedValues = Self.parseConfig(verifiedConfig)
            guard nonempty(verifiedValues["user_token"]) != nil else {
                return .unavailable("Google did not return a reusable session. Please sign in again.")
            }
            try fm.createDirectory(at: GPlayDLClient.workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for name in Self.cliSessionFiles + ["device.conf"] {
                let source = scratch.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) {
                    let data = try Data(contentsOf: source)
                    let target = GPlayDLClient.workDir.appendingPathComponent(name)
                    try data.write(to: target, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                }
            }
            // Access-token exchange returns an identity from Google. The
            // legacy master-token check can echo its input email, so do not
            // advertise that remembered string as a verified identity.
            let verifiedEmail = master == nil ? nonempty(verifiedValues["user_email"]) : nil
            return .verified(email: verifiedEmail?.contains("@") == true ? verifiedEmail : nil)
        } catch {
            return .unavailable("Could not verify the Google session. Check your connection and retry.")
        }
    }

    static func writePrivate(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func signIn(fresh: Bool) async -> GoogleSignInResult {
        await GoogleSignInController.shared.signIn(fresh: fresh)
    }

    func cancelSignIn() { GoogleSignInController.shared.cancel() }

    func accept(_ credentials: GoogleSignInCredentials) throws {
        // A completed new browser attempt replaces the old identity rather
        // than letting an old CLI config silently take precedence over it.
        try clearLocalCredentials()
        PlaySessionStore.save(cookies: credentials.cookies, email: credentials.email)
        if let token = credentials.cookies["oauth_token"] { HarborPlayTokenBridge.saveOAuthToken(token) }
        HarborPlayTokenBridge.saveAccountEmail(credentials.email)
    }

    func clear() async throws {
        var failure: Error?
        do { try clearLocalCredentials() } catch { failure = error }
        await clearBrowserCookies()
        do {
            let accounts = try await metadata.loadAccounts().filter { $0.providerID != .googlePlay }
            try await metadata.saveAccounts(accounts)
        } catch { failure = error }
        if let failure { throw failure }
    }

    private func clearLocalCredentials() throws {
        var failure: Error?
        for clear in [{ try HarborPlayTokenBridge.clearSession() },
                      { try PlaySessionStore.clear() },
                      { try PlayCredentialBackup.clear() }] {
            do { try clear() } catch { failure = error }
        }
        for name in Self.cliSessionFiles {
            let url = GPlayDLClient.workDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) } catch { failure = error }
            }
        }
        if let failure { throw failure }
    }
}
