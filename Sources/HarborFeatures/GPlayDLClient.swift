import Foundation
import HarborRuntime

/// Bridge to the community Google-Play-API CLI tools (gplaydl/gplayver,
/// vendored under Vendor/Google-Play-API and bundled into the app by
/// Scripts/bundle_gplaydl.sh).
///
/// Google's delivery gateway rejects Harbor's independent Play client with
/// HTTP 400 but accepts this client's requests (verified live 2026-09-19:
/// details + full delivery of Minecraft 1.26.51.1, versionCode 972605101).
/// The first run exchanges the sign-in window's access token (oauth2_4/...)
/// for a master token that gplaydl persists in PlayAPI/playdl.conf — later
/// runs need no sign-in at all.
/// Google Play credentials mirrored OUTSIDE Application Support (which every
/// app wipe deletes): a chmod-600 JSON dotfile in the user's home. A wipe then
/// costs a re-download — never a re-login.
enum PlayCredentialBackup {
    struct Payload: Codable {
        var oauth: String?
        var master: String?
        var email: String?
    }

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bedrockharbor/credentials.json", isDirectory: false)
    }

    static func load() -> Payload {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return Payload(oauth: nil, master: nil, email: nil) }
        return payload
    }

    static func save(oauth: String? = nil, master: String? = nil, email: String? = nil) {
        var payload = load()
        if let oauth { payload.oauth = oauth }
        if let master { payload.master = master }
        if let email { payload.email = email }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    static func clearMaster() {
        var payload = load()
        guard payload.master != nil else { return }
        payload.master = nil
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

@MainActor
enum GPlayDLClient {

    struct DownloadResult {
        let files: [URL]
        let versionName: String
        let stagingDir: URL
    }

    nonisolated static var workDir: URL {
        LocalRuntimeDiscovery.harborSupport.appendingPathComponent("PlayAPI", isDirectory: true)
    }

    static func locateBinary(named name: String) -> URL? {
        for base in [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS"),
                     Bundle.main.resourceURL ?? Bundle.main.bundleURL] {
            let candidate = base.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Downloads Minecraft via gplaydl. Returns nil (with a status note) when
    /// the tools are missing, sign-in is required, or Google rejects the call.
    static func download(
        oauth: String?,
        email: String?,
        status: @escaping (String) -> Void,
        progress: ((Double, String) -> Void)? = nil
    ) async -> DownloadResult? {
        guard let dl = locateBinary(named: "gplaydl"), let ver = locateBinary(named: "gplayver") else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let backup = PlayCredentialBackup.load()
        let hasSavedAuth = ensureDeviceConfig()
        let authPlan = Self.authArgs(
            hasSavedConf: hasSavedAuth,
            backupMaster: backup.master,
            backupEmail: backup.email,
            oauth: oauth ?? backup.oauth,
            email: email ?? backup.email
        )
        guard let authArgs = authPlan.args else {
            status("Play download needs Google sign-in once — open Android setup")
            return nil
        }

        // Version first — it also names the installation directory, which the
        // compatibility rules match on, so the real string (e.g. 1.26.51.1) is
        // required, not the numeric Play versionCode.
        status("Google Play: checking latest Minecraft version…")
        let verArgs = ["--device", "device.conf", "--app", "com.mojang.minecraftpe", "--accept-tos"] + authArgs
        var versionRun = await run(ver, verArgs)
        if versionRun.code != 0,
           !versionRun.err.contains("bad token"), !versionRun.err.contains("bad saved token") {
            // The first-ever run does a device checkin and can fail cold once —
            // retry before reporting anything; without this, Install "works on
            // the second click" and shows a scary error the first time.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            status("Google Play: retrying version check…")
            versionRun = await run(ver, verArgs)
        }
        guard versionRun.code == 0,
              let matched = versionRun.out.range(of: #"version string: \S+"#, options: .regularExpression)
        else {
            let err = versionRun.err
            if err.contains("bad token") || err.contains("bad saved token") {
                // Expired/revoked credentials: drop them so the next run asks
                // for a fresh sign-in instead of failing forever.
                try? fm.removeItem(at: workDir.appendingPathComponent("playdl.conf"))
                PlayCredentialBackup.clearMaster()
                status("Google login expired — sign in once more, then Install")
            } else {
                status("Play version check failed: \(err.isEmpty ? versionRun.out : err)")
            }
            return nil
        }
        // The version call may have just exchanged an access token for the
        // long-lived master token — mirror it to the wipe-surviving backup.
        persistMasterToBackup()
        let versionName = String(versionRun.out[matched])
            .replacingOccurrences(of: "version string: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let staging = workDir.appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        status("Google Play: downloading Minecraft \(versionName)…")
        let progressForwarder = StatusForwarder { line in
            Task { @MainActor in
                status("Google Play: \(line)")
                if let parsed = Self.parseProgress(line) {
                    progress?(parsed.percent, parsed.detail)
                }
            }
        }
        let downloadRun = await run(dl, [
            "--device", "device.conf", "--app", "com.mojang.minecraftpe", "--accept-tos",
            "-o", staging.appendingPathComponent("mc.apk").path,
        ] + authArgs, progress: progressForwarder)
        guard downloadRun.code == 0 else {
            status("Play download failed: \(downloadRun.err)")
            try? fm.removeItem(at: staging)
            return nil
        }
        let apks = ((try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "apk" }
        guard !apks.isEmpty else {
            try? fm.removeItem(at: staging)
            return nil
        }
        persistMasterToBackup()
        return DownloadResult(files: apks, versionName: versionName, stagingDir: staging)
    }

    /// "Downloaded 45% [400/886 MiB]" → (0.45, "400/886 MiB").
    static func parseProgress(_ line: String) -> (percent: Double, detail: String)? {
        guard let fragment = line.range(of: #"Downloaded \d+% \[\d+/\d+ \w+\]"#, options: .regularExpression)
        else { return nil }
        let text = String(line[fragment])
        guard let pctToken = text.range(of: #"\d+%"#, options: .regularExpression),
              let percent = Double(text[pctToken].dropLast())
        else { return nil }
        var detail = ""
        if let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close {
            detail = String(text[text.index(after: open)..<close])
        }
        return (percent / 100, detail)
    }

    /// Credential priority for the CLI: an existing playdl.conf (nothing
    /// needed), then the backed-up master token, then the sign-in access token.
    static func authArgs(
        hasSavedConf: Bool,
        backupMaster: String?,
        backupEmail: String?,
        oauth: String?,
        email: String?
    ) -> (args: [String]?, usedBackupMaster: Bool) {
        if hasSavedConf { return ([], false) }
        if let master = backupMaster, !master.isEmpty {
            return (["--token", master, "--email", backupEmail ?? "", "--save-auth"], true)
        }
        if let oauth, !oauth.isEmpty {
            return (["--access-token", oauth, "--email", email ?? "", "--save-auth"], false)
        }
        return (nil, false)
    }

    /// Mirrors playdl.conf's long-lived master token into the wipe-surviving
    /// backup so the login outlives Application Support wipes.
    static func persistMasterToBackup() {
        let conf = workDir.appendingPathComponent("playdl.conf")
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return }
        var token: String?
        var email: String?
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 {
                if kv[0] == "user_token" { token = kv[1] }
                if kv[0] == "user_email" { email = kv[1] }
            }
        }
        guard let token, !token.isEmpty else { return }
        PlayCredentialBackup.save(master: token, email: email)
    }

    /// Writes the arm64 device config once. Returns true when a saved master
    /// token exists (no access token needed for this run).
    private static func ensureDeviceConfig() -> Bool {
        let fm = FileManager.default
        let deviceConf = workDir.appendingPathComponent("device.conf")
        if !fm.fileExists(atPath: deviceConf.path) {
            try? """
            config.native_platforms = [
                arm64-v8a
            ]

            """.write(to: deviceConf, atomically: true, encoding: .utf8)
        }
        return fm.fileExists(atPath: workDir.appendingPathComponent("playdl.conf").path)
    }

    /// Runs a CLI tool in the PlayAPI working directory. The wait happens on a
    /// background queue so a long download never blocks the UI. When `progress`
    /// is given, gplaydl's \r-separated "Downloaded N%" lines are streamed to
    /// it once per second — a silent multi-minute download looks stuck and
    /// invites duplicate clicks.
    private nonisolated static func run(
        _ binary: URL,
        _ args: [String],
        progress: StatusForwarder? = nil
    ) async -> (code: Int32, out: String, err: String) {
        let outBox = PipeBuffer()
        let errBox = PipeBuffer()
        let p = Process()
        p.executableURL = binary
        p.currentDirectoryURL = workDir
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { outBox.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { errBox.append(chunk) }
        }
        do {
            try p.run()
            let exitBox = ExitFlag()
            let waiter = Task {
                p.waitUntilExit()
                exitBox.set()
            }
            if progress != nil {
                while !exitBox.isSet {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if let line = errBox.progressLine { progress?.send(line) }
                }
            }
            await waiter.value
        } catch {
            return (-1, "", error.localizedDescription)
        }
        // Let trailing pipe data land before reading the buffers.
        try? await Task.sleep(nanoseconds: 50_000_000)
        return (p.terminationStatus, outBox.string, errBox.string)
    }
}

private final class ExitFlag: @unchecked Sendable {
    private var exited = false
    private let lock = NSLock()
    func set() { lock.lock(); exited = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return exited }
}

/// Delivers progress lines off the main actor; the handler only schedules a
/// MainActor task, so the unchecked Sendable is safe.
private final class StatusForwarder: @unchecked Sendable {
    private let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    func send(_ line: String) { handler(line) }
}

private final class PipeBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) {
        lock.lock()
        data += chunk
        lock.unlock()
    }
    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
    /// Last "Downloaded N% [x/y MiB]" fragment; gplaydl progress uses \r, not \n.
    var progressLine: String? {
        lock.lock()
        defer { lock.unlock() }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .last(where: { $0.contains("Downloaded") })
            .map(String.init)
    }
}
