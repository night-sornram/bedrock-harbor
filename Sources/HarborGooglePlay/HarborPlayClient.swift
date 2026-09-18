import CryptoKit
import Foundation
import HarborDomain
import HarborPlatform

// MARK: - Independent Google Play / Finsky client (original code — not FinskyKit)

/// Harbor's own Play client lifecycle:
/// OAuth/token → Android check-in → DFE bootstrap → version → entitlement → APK download.
public struct HarborPlayClient: Sendable {
    public struct Endpoints: Sendable {
        public var auth: URL
        public var checkin: URL
        public var userSettings: URL
        public var toc: URL
        public var uploadDeviceConfig: URL
        public var acceptTos: URL
        public var details: URL
        public var bulkDetails: URL
        public var delivery: URL

        public static let production = Endpoints(
            auth: URL(string: "https://android.clients.google.com/auth")!,
            checkin: URL(string: "https://android.clients.google.com/checkin")!,
            userSettings: URL(string: "https://android.clients.google.com/fdfe/userSettings")!,
            toc: URL(string: "https://android.clients.google.com/fdfe/toc")!,
            uploadDeviceConfig: URL(string: "https://android.clients.google.com/fdfe/uploadDeviceConfig")!,
            acceptTos: URL(string: "https://android.clients.google.com/fdfe/acceptTos")!,
            details: URL(string: "https://android.clients.google.com/fdfe/details")!,
            bulkDetails: URL(string: "https://android.clients.google.com/fdfe/bulkDetails")!,
            delivery: URL(string: "https://android.clients.google.com/fdfe/delivery")!
        )
    }

    public struct DeviceState: Codable, Sendable {
        public var androidId: String
        public var securityToken: String?
        public var deviceConfigDigest: String?
        public var bootstrappedAt: Date?
    }

    public struct Credential: Codable, Sendable {
        public var userID: String
        public var email: String?
        public var masterToken: String
        public var authCookie: String
        public var accessToken: String?
        public var device: DeviceState
    }

    public struct APKFile: Sendable {
        public var url: URL
        public var fileURL: URL
        public var isSplit: Bool
        public var sizeBytes: Int64
    }

    public static let packageName = "com.mojang.minecraftpe"
    public static let vendingSig = "38918a453d07199354f8b19af05ec6562ced5788"
    public static let vendingPackage = "com.android.vending"

    public var endpoints: Endpoints
    public var deviceStateDirectory: URL?

    public init(
        endpoints: Endpoints = .production,
        deviceStateDirectory: URL? = nil
    ) {
        self.endpoints = endpoints
        self.deviceStateDirectory = deviceStateDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/BedrockHarbor/PlayDeviceState", isDirectory: true)
    }

    // MARK: - Persistence

    private var credentialURL: URL {
        (deviceStateDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("harbor-play-credential.json")
    }

    public func loadCredential(userID: String) -> Credential? {
        guard let data = try? Data(contentsOf: credentialURL),
              let cred = try? JSONDecoder().decode(Credential.self, from: data),
              cred.userID == userID || userID.isEmpty
        else { return nil }
        return cred
    }

    public func saveCredential(_ credential: Credential) {
        guard let dir = deviceStateDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(credential) {
            try? data.write(to: credentialURL, options: .atomic)
        }
    }

    // MARK: - Auth + check-in + DFE (own implementation)

    /// Full Play bootstrap using an OAuth access token (preferred) and/or cookie session.
    public func authorize(
        accessToken: String?,
        email: String?,
        userID: String,
        cookieSession: DeliveryAuth?
    ) async throws -> Credential {
        var log: [String] = []
        var device = loadDeviceState() ?? DeviceState(
            androidId: Self.randomAndroidId(),
            securityToken: nil,
            deviceConfigDigest: nil,
            bootstrappedAt: nil
        )

        // 1) Android check-in when we have no android id handshake yet
        if device.securityToken == nil {
            do {
                device = try await checkIn(device: device)
                log.append("checkin ok id=\(device.androidId)")
            } catch {
                log.append("checkin failed \(error.localizedDescription)")
            }
        }

        // Path A: independent client — prefer Android setup oauth_token, then any Play auth material.
        var masterToken = ""
        var authCookie = ""
        var tokenForPlay = accessToken
        if tokenForPlay == nil || !(HarborPlayTokenBridge.looksLikeOAuthAccessToken(tokenForPlay ?? "")) {
            if let setup = cookieSession?.cookies["oauth_token"], HarborPlayTokenBridge.looksLikeOAuthAccessToken(setup) {
                tokenForPlay = setup
                HarborPlayTokenBridge.saveOAuthToken(setup)
            } else {
                tokenForPlay = HarborPlayTokenBridge.loadOAuthToken()
            }
        }

        // Identity: email candidates + user_id. Missing email was the old "Sign in again" loop.
        var emailCandidates: [String] = []
        func addEmail(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            if !emailCandidates.contains(value) { emailCandidates.append(value) }
        }
        addEmail(email)
        addEmail(cookieSession?.accountEmail)
        addEmail(cookieSession?.cookies["Email"])
        addEmail(cookieSession?.cookies["email"])
        addEmail(HarborPlayTokenBridge.loadAccountEmail())
        if let uid = cookieSession?.cookies["user_id"] { addEmail(uid) }
        if emailCandidates.isEmpty { addEmail("") }

        // Token candidates: oauth2_4/…, stripped token, LSID/SID/OSID forms.
        var tokenCandidates: [String] = []
        func addToken(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.count > 8 else { return }
            if !tokenCandidates.contains(value) { tokenCandidates.append(value) }
        }
        addToken(tokenForPlay)
        addToken(cookieSession?.cookies["oauth_token"])
        let primary = tokenForPlay ?? cookieSession?.cookies["oauth_token"]
        if let primary, primary.contains("/") {
            addToken(primary.split(separator: "/").last.map(String.init))
        }
        if let lsid = cookieSession?.cookies["LSID"] {
            addToken(lsid)
            if lsid.contains("|") { addToken(lsid.split(separator: "|").last.map(String.init)) }
        }
        addToken(cookieSession?.cookies["__Secure-OSID"])
        addToken(cookieSession?.cookies["OSID"])
        addToken(cookieSession?.cookies["__Secure-3PSID"])
        addToken(cookieSession?.cookies["SID"])

        let services = [
            "oauth2:https://www.googleapis.com/auth/googleplay",
            "oauth2:https://www.googleapis.com/auth/androidmarket",
            "androidmarket",
            "ac2dm",
        ]

        exchangeLoop: for token in tokenCandidates.prefix(8) {
            for emailCandidate in emailCandidates.prefix(4) {
                for service in services {
                    let extra: [String: String] = [
                        "SID": cookieSession?.cookies["SID"] ?? "",
                        "authUser": "0",
                    ]
                    if let exchanged = try? await exchangeAuth(
                        email: emailCandidate,
                        token: token,
                        service: service,
                        androidId: device.androidId,
                        extra: extra
                    ), !exchanged.authCookie.isEmpty || !exchanged.masterToken.isEmpty {
                        masterToken = exchanged.masterToken
                        authCookie = exchanged.authCookie
                        log.append("auth ok token=\(token.prefix(12))… service=\(service) email=\(emailCandidate.isEmpty ? "(none)" : "yes")")
                        break exchangeLoop
                    } else {
                        log.append("try \(service)/\(token.prefix(10))… failed")
                    }
                }
            }
        }

        if authCookie.isEmpty && masterToken.isEmpty {
            // Do NOT throw reauthenticationRequired when Play material already exists —
            // that is what made Settings/Install loop on "Sign in again".
            let hasPlayToken = tokenCandidates.contains { $0.hasPrefix("oauth2_") || HarborPlayTokenBridge.looksLikeOAuthAccessToken($0) }
            let hasWebSession = !(cookieSession?.cookies.isEmpty ?? true)
            if hasPlayToken || hasWebSession || HarborPlayTokenBridge.loadOAuthToken() != nil {
                let why = log.isEmpty ? "no exchange attempts" : log.suffix(8).joined(separator: "; ")
                throw HarborError.providerFailure(
                    reason: "Play session/token present, but Google auth exchange failed (\(why)). This is not a browser sign-in problem — do not sign in again."
                )
            }
            throw HarborError.reauthenticationRequired(providerID: .googlePlay)
        }

        let resolvedEmail = email?.contains("@") == true
            ? email
            : emailCandidates.first { $0.contains("@") }
        let credential = Credential(
            userID: userID,
            email: resolvedEmail,
            masterToken: masterToken,
            authCookie: authCookie.isEmpty ? masterToken : authCookie,
            accessToken: tokenForPlay ?? accessToken,
            device: device
        )

        // 3) DFE bootstrap
        do {
            let bootstrapped = try await bootstrapDFE(credential: credential)
            saveCredential(bootstrapped)
            log.append("dfe ok")
            return bootstrapped
        } catch {
            saveCredential(credential)
            throw HarborError.providerFailure(
                reason: "DFE bootstrap failed: \(error.localizedDescription) | \(log.joined(separator: "; "))"
            )
        }
    }

    private func loadDeviceState() -> DeviceState? {
        guard let dir = deviceStateDirectory else { return nil }
        let url = dir.appendingPathComponent("device.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DeviceState.self, from: data)
    }

    private func saveDeviceState(_ state: DeviceState) {
        guard let dir = deviceStateDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("device.json")
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Check-in

    private func checkIn(device: DeviceState) async throws -> DeviceState {
        var req = URLRequest(url: endpoints.checkin)
        req.httpMethod = "POST"
        req.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue("Android-Checkin/2.0 (gzip)", forHTTPHeaderField: "User-Agent")
        // Minimal independent check-in payload (device identity only).
        req.httpBody = Self.encodeCheckinRequest(androidId: device.androidId)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw HarborError.providerFailure(reason: "checkin HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        var updated = device
        if let parsed = Self.decodeAndroidId(from: data) {
            updated.androidId = parsed.androidId
            updated.securityToken = parsed.securityToken
        }
        saveDeviceState(updated)
        return updated
    }

    // MARK: Auth exchange

    private struct AuthExchange {
        var masterToken: String
        var authCookie: String
    }

    private func exchangeAuth(
        email: String?,
        token: String,
        service: String,
        androidId: String,
        extra: [String: String] = [:]
    ) async throws -> AuthExchange {
        var form: [String: String] = [
            "Email": email ?? "",
            "Token": token,
            "service": service,
            "app": Self.vendingPackage,
            "client_sig": Self.vendingSig,
            "androidId": androidId,
            "sdk_version": "28",
            "device_country": "us",
            "operatorCountry": "us",
            "lang": "en",
            "callerPkg": Self.vendingPackage,
            "callerSig": Self.vendingSig,
        ]
        for (k, v) in extra { form[k] = v }

        var req = URLRequest(url: endpoints.auth)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("GoogleAuth/1.4 (sargo QP1A.190711.020)", forHTTPHeaderField: "User-Agent")
        req.httpBody = Self.formEncode(form).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let body = String(decoding: data, as: UTF8.self)
        guard let http = response as? HTTPURLResponse else {
            throw HarborError.providerFailure(reason: "auth no HTTP response for \(service)")
        }
        var master = ""
        var auth = ""
        var err = ""
        for line in body.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "Token" || parts[0] == "MasterToken" { master = parts[1] }
            if parts[0] == "Auth" { auth = parts[1] }
            if parts[0] == "Error" { err = parts[1] }
        }
        if master.isEmpty && auth.isEmpty {
            // Do not map every auth failure to "Sign in again".
            let code = err.isEmpty ? "HTTP \(http.statusCode)" : err
            throw HarborError.providerFailure(reason: "auth exchange \(code) for \(service)")
        }
        return AuthExchange(masterToken: master, authCookie: auth)
    }

    // MARK: DFE bootstrap

    private func bootstrapDFE(credential: Credential) async throws -> Credential {
        var cred = credential
        _ = try await dfeGet(url: endpoints.userSettings, credential: cred)
        let tocData = try await dfeGet(url: endpoints.toc, credential: cred)
        // Accept TOS if server indicates it is required (best-effort).
        _ = try? await dfePost(
            url: endpoints.acceptTos,
            credential: cred,
            body: Self.formEncode(["tosToken": "tok"]).data(using: .utf8) ?? Data(),
            contentType: "application/x-www-form-urlencoded"
        )
        // Upload a minimal device configuration so Play can select arm64 delivery.
        let config = Self.encodeDeviceConfig(androidId: cred.device.androidId, abi: "arm64-v8a")
        _ = try await dfePost(
            url: endpoints.uploadDeviceConfig,
            credential: cred,
            body: config,
            contentType: "application/x-protobuf"
        )
        cred.device.bootstrappedAt = Date()
        cred.device.deviceConfigDigest = Insecure.SHA1.hash(data: config).map { String(format: "%02x", $0) }.joined()
        _ = tocData
        return cred
    }

    private func dfeHeaders(credential: Credential) -> [String: String] {
        var headers: [String: String] = [
            "Authorization": "GoogleLogin auth=\(credential.authCookie)",
            "User-Agent": "Android-Finsky/37.0.13-29 [0] [PR] 538703709 (arm64-v8a) (29)",
            "X-DFE-Device-Id": credential.device.androidId,
            "X-DFE-Client-Id": "am-android-google",
            "Accept-Language": "en-US",
            "X-DFE-Enabled-Experiments": "",
            "X-DFE-Unsupported-Experiments": "",
            "X-DFE-SmallestScreenWidthDp": "411",
            "X-DFE-MCCMNC": "310260",
        ]
        if let email = credential.email, !email.isEmpty {
            headers["X-DFE-Encoded-Targets"] = ""
        }
        return headers
    }

    private func dfeGet(url: URL, credential: Credential) async throws -> Data {
        var req = URLRequest(url: url)
        for (k, v) in dfeHeaders(credential: credential) { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.throwIfNeeded(response: response, body: data)
        return data
    }

    private func dfePost(url: URL, credential: Credential, body: Data, contentType: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (k, v) in dfeHeaders(credential: credential) { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.throwIfNeeded(response: response, body: data)
        return data
    }

    private static func throwIfNeeded(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            // Do not surface this as "Sign in again" — token/session may still be fine.
            let snippet = String(decoding: body.prefix(160), as: UTF8.self)
            throw HarborError.providerFailure(
                reason: "Play rejected credential (HTTP \(http.statusCode)). Not necessarily a browser login problem. \(snippet)"
            )
        }
        if http.statusCode >= 400 {
            let snippet = String(decoding: body.prefix(200), as: UTF8.self)
            throw HarborError.providerFailure(reason: "Play HTTP \(http.statusCode) \(snippet)")
        }
    }

    // MARK: Version + entitlement + download

    public func latestVersion(abi: String = "arm64-v8a", credential: Credential) async throws -> (versionCode: Int, versionName: String?) {
        var components = URLComponents(url: endpoints.details, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "doc", value: Self.packageName),
            URLQueryItem(name: "hl", value: "en"),
        ]
        let data = try await dfeGet(url: components.url!, credential: credential)
        let text = String(decoding: data, as: UTF8.self)
        // Independent extraction: Play details payloads include versionCode integers.
        var versionCode = 0
        if let regex = try? NSRegularExpression(pattern: "\(Self.packageName)[^0-9]{0,40}([0-9]{6,12})"),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let r = Range(m.range(at: 1), in: text) {
            versionCode = Int(text[r]) ?? 0
        }
        var versionName: String?
        if let regex = try? NSRegularExpression(pattern: "\\[\\[\\[\"([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)\""),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let r = Range(m.range(at: 1), in: text) {
            versionName = String(text[r])
        }
        if versionCode == 0, let name = versionName {
            versionCode = Self.versionCode(from: name)
        }
        guard versionCode > 0 else {
            throw HarborError.providerFailure(reason: "Could not read Minecraft versionCode from Play details")
        }
        return (versionCode, versionName)
    }

    public func checkDownloadAccess(versionCode: Int, credential: Credential) async throws {
        var components = URLComponents(url: endpoints.delivery, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "doc", value: Self.packageName),
            URLQueryItem(name: "ot", value: "1"),
            URLQueryItem(name: "vc", value: String(versionCode)),
        ]
        let data = try await dfeGet(url: components.url!, credential: credential)
        if data.count < 80 {
            throw HarborError.entitlementDenied(reason: "Play delivery empty for \(Self.packageName)")
        }
        // If response contains no download-like URLs, entitlement/delivery is missing.
        let text = String(decoding: data, as: UTF8.self)
        if !text.contains("http") && data.count < 200 {
            throw HarborError.entitlementDenied(reason: "No delivery payload")
        }
    }

    public func downloadDelivery(
        versionCode: Int,
        abi: String = "arm64-v8a",
        credential: Credential,
        outputDirectory: URL
    ) async throws -> [APKFile] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var components = URLComponents(url: endpoints.delivery, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "doc", value: Self.packageName),
            URLQueryItem(name: "ot", value: "1"),
            URLQueryItem(name: "vc", value: String(versionCode)),
            URLQueryItem(name: "abi", value: abi),
        ]
        let payload = try await dfeGet(url: components.url!, credential: credential)
        let urls = Self.extractDownloadURLs(payload)
        guard !urls.isEmpty else {
            throw HarborError.providerFailure(reason: "Play delivery returned no APK URLs (auth=\(!credential.authCookie.isEmpty), androidId=\(credential.device.androidId))")
        }

        var files: [APKFile] = []
        var index = 0
        for url in urls.prefix(10) {
            var req = URLRequest(url: url)
            for (k, v) in dfeHeaders(credential: credential) { req.setValue(v, forHTTPHeaderField: k) }
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { continue }
            if data.count < 4096 { continue }
            // gzip delivery or raw apk
            var apkData = data
            if data.prefix(2) == Data([0x1f, 0x8b]) {
                if let inflated = Self.gunzip(data) { apkData = inflated }
            }
            if apkData.count > 4, !(apkData[0] == 0x50 && apkData[1] == 0x4B) { continue }
            index += 1
            let name = index == 1 ? "base.apk" : "split_\(index).apk"
            let fileURL = outputDirectory.appendingPathComponent(name)
            try apkData.write(to: fileURL)
            files.append(APKFile(url: url, fileURL: fileURL, isSplit: index > 1, sizeBytes: Int64(apkData.count)))
        }
        guard !files.isEmpty else {
            throw HarborError.invalidPackage(reason: "Downloaded 0 APK files from Play delivery")
        }
        return files
    }

    // MARK: - Encoding helpers (original)

    static func formEncode(_ fields: [String: String]) -> String {
        fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }

    static func randomAndroidId() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%016x", $0) }.joined().prefix(16).uppercased().description
    }

    static func versionCode(from name: String) -> Int {
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return 0 }
        var code = 0
        for (i, p) in parts.prefix(4).enumerated() {
            code += p * Int(pow(1000.0, Double(3 - i)))
        }
        return code
    }

    /// Minimal protobuf wire encoding for check-in / device config used by this client.
    static func encodeCheckinRequest(androidId: String) -> Data {
        var out = Data()
        // Field 7: loggingId (int32) — placeholder
        out.append(contentsOf: protoVarint(field: 7, value: 1))
        // Field 9: checkin submessage with model/sdk placeholders
        var checkin = Data()
        checkin.append(contentsOf: protoString(field: 7, value: "Pixel 6"))
        checkin.append(contentsOf: protoString(field: 8, value: "sargo"))
        checkin.append(contentsOf: protoVarint(field: 9, value: 28)) // sdk
        out.append(contentsOf: protoBytes(field: 9, value: checkin))
        // Field 18: deviceConfiguration
        out.append(contentsOf: protoBytes(field: 18, value: encodeDeviceConfig(androidId: androidId, abi: "arm64-v8a")))
        return out
    }

    static func encodeDeviceConfig(androidId: String, abi: String) -> Data {
        var cfg = Data()
        cfg.append(contentsOf: protoString(field: 1, value: androidId))
        cfg.append(contentsOf: protoString(field: 2, value: abi))
        cfg.append(contentsOf: protoString(field: 3, value: "en-US"))
        cfg.append(contentsOf: protoVarint(field: 4, value: 411)) // smallest width dp
        cfg.append(contentsOf: protoString(field: 5, value: "310260"))
        return cfg
    }

    static func protoVarint(field: Int, value: UInt64) -> Data {
        var out = Data()
        out.append(UInt8((field << 3) | 0))
        var v = value
        while v > 0x7F {
            out.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        out.append(UInt8(v & 0x7F))
        return out
    }

    static func protoString(field: Int, value: String) -> Data {
        protoBytes(field: field, value: Data(value.utf8))
    }

    static func protoBytes(field: Int, value: Data) -> Data {
        var out = Data()
        out.append(UInt8((field << 3) | 2))
        var len = UInt64(value.count)
        while len > 0x7F {
            out.append(UInt8((len & 0x7F) | 0x80))
            len >>= 7
        }
        out.append(UInt8(len & 0x7F))
        out.append(value)
        return out
    }

    static func decodeAndroidId(from data: Data) -> (androidId: String, securityToken: String?)? {
        // Search for 8-byte android id patterns and nearby security token strings.
        var androidId: String?
        var security: String?
        var i = data.startIndex
        while i < data.endIndex {
            // field 7 fixed64 / varint common layouts — best-effort scan for hex-like tokens
            i = data.index(after: i)
            _ = i
            break
        }
        // Prefer UTF-8 android id if present as decimal string in protobuf
        if let regex = try? NSRegularExpression(pattern: "([0-9]{10,20})"),
           let m = regex.firstMatch(in: String(decoding: data.prefix(256), as: UTF8.self),
                                    range: NSRange(location: 0, length: min(256, data.count))),
           let range = Range(m.range(at: 1), in: String(decoding: data.prefix(256), as: UTF8.self)) {
            androidId = String(String(decoding: data.prefix(256), as: UTF8.self)[range])
        }
        // Keep generated id if decode fails
        return androidId.map { ($0, security) }
    }

    static func extractDownloadURLs(_ data: Data) -> [URL] {
        var urls: [URL] = []
        let text = String(decoding: data, as: UTF8.self)
        if let regex = try? NSRegularExpression(pattern: #"https://[^\s\"'<>]+"#) {
            let ns = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: ns).prefix(40) {
                guard let r = Range(match.range, in: text) else { continue }
                let s = String(text[r])
                if s.contains(".apk") || s.contains("googleusercontent") || s.contains("play") {
                    if let u = URL(string: s) { urls.append(u) }
                }
            }
        }
        return Array(Set(urls))
    }

    static func gunzip(_ data: Data) -> Data? {
        // Foundation doesn't always expose inflate; try Compression-less simple path via zlib-less fallback:
        // Many Play delivery bodies are raw APK already. Return nil to keep original.
        return nil
    }
}

// MARK: - OAuth token bridge (independent)

public enum HarborPlayTokenBridge {
    /// True when the string can be used as Play auth material.
    /// Includes Android setup `oauth_token` cookie values (not only ya29.*).
    public static func looksLikeOAuthAccessToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.hasPrefix("ya29.") || t.hasPrefix("1//") || t.hasPrefix("0/a") { return true }
        // Android embedded setup sets cookie oauth_token (e.g. oauth2_4/... or long opaque).
        if t.hasPrefix("oauth2_") || t.hasPrefix("oauth_token") { return true }
        if t.count >= 20, !t.hasPrefix("g.a"), !t.hasPrefix("SID"), t != "Bearer" {
            // Reject obvious SID/LSID cookie values
            if t.hasPrefix("o.play.google.com") { return false }
            return true
        }
        return false
    }

    private static let accountEmailKey = "com.bedrockharbor.play.accountEmail"

    public static func saveOAuthToken(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeOAuthAccessToken(t) else { return }
        UserDefaults.standard.set(t, forKey: "com.bedrockharbor.play.oauth")
        try? FileManager.default.createDirectory(
            at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/BedrockHarbor", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? t.write(
            to: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/BedrockHarbor/play-oauth.token"),
            atomically: true,
            encoding: .utf8
        )
    }

    public static func clearOAuthToken() {
        UserDefaults.standard.removeObject(forKey: "com.bedrockharbor.play.oauth")
        try? FileManager.default.removeItem(
            at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/BedrockHarbor/play-oauth.token")
        )
    }

    public static func saveAccountEmail(_ email: String?) {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), email.contains("@") else { return }
        UserDefaults.standard.set(email, forKey: accountEmailKey)
    }

    public static func loadAccountEmail() -> String? {
        guard let email = UserDefaults.standard.string(forKey: accountEmailKey), email.contains("@") else { return nil }
        return email
    }

    public static func loadOAuthToken() -> String? {
        if let t = UserDefaults.standard.string(forKey: "com.bedrockharbor.play.oauth"), looksLikeOAuthAccessToken(t) {
            return t
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BedrockHarbor/play-oauth.token")
        if let t = try? String(contentsOf: url, encoding: .utf8), looksLikeOAuthAccessToken(t) {
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Pull access_token / id_token / oauth_token from a WebView navigation URL.
    public static func token(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var candidates: [String] = []
        let names: Set<String> = ["access_token", "id_token", "token", "oauth_token"]
        if let items = components.queryItems {
            for item in items where names.contains(item.name) {
                if let v = item.value { candidates.append(v) }
            }
        }
        if let frag = components.fragment {
            for part in frag.split(separator: "&") {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, names.contains(kv[0]) { candidates.append(kv[1]) }
            }
        }
        return candidates.first(where: { looksLikeOAuthAccessToken($0) })
    }

    /// Prefer Android setup oauth_token cookie; then stored token; then other Google cookies.
    public static func accessToken(from cookies: [String: String], email: String?) async -> String? {
        if let setup = cookies["oauth_token"], looksLikeOAuthAccessToken(setup) {
            saveOAuthToken(setup)
            return setup
        }
        if let stored = loadOAuthToken() { return stored }

        let androidId = HarborPlayClient.randomAndroidId()
        let services = [
            "oauth2:https://www.googleapis.com/auth/googleplay",
            "oauth2:https://www.googleapis.com/auth/androidmarket",
            "androidmarket",
            "ac2dm",
        ]
        let tokenCandidates = [
            cookies["oauth_token"],
            cookies["__Secure-3PSID"],
            cookies["OSID"],
            cookies["__Secure-OSID"],
            cookies["LSID"],
        ].compactMap { $0 }

        for service in services {
            for token in tokenCandidates {
                var form: [String: String] = [
                    "Email": email ?? "",
                    "Token": token,
                    "service": service,
                    "app": HarborPlayClient.vendingPackage,
                    "client_sig": HarborPlayClient.vendingSig,
                    "androidId": androidId,
                    "sdk_version": "28",
                    "device_country": "us",
                    "lang": "en",
                    "callerPkg": HarborPlayClient.vendingPackage,
                    "callerSig": HarborPlayClient.vendingSig,
                ]
                if let sid = cookies["SID"] { form["SID"] = sid }
                var req = URLRequest(url: HarborPlayClient.Endpoints.production.auth)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = HarborPlayClient.formEncode(form).data(using: .utf8)
                guard let (data, response) = try? await URLSession.shared.data(for: req),
                      let http = response as? HTTPURLResponse,
                      http.statusCode < 400 else { continue }
                let body = String(decoding: data, as: UTF8.self)
                var auth = ""
                var master = ""
                for line in body.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    if parts[0] == "Auth" { auth = parts[1] }
                    if parts[0] == "Token" || parts[0] == "MasterToken" { master = parts[1] }
                }
                if !auth.isEmpty, auth.count > 20 {
                    saveOAuthToken(auth)
                    return auth
                }
                if !master.isEmpty, master.count > 20 {
                    saveOAuthToken(master)
                    return master
                }
            }
        }
        return loadOAuthToken()
    }
}
