import CryptoKit
import Foundation
import HarborDomain
import HarborPlatform

/// Independent Play delivery client. Downloads Minecraft for the signed-in Google account.
public struct PlayDeliveryClient: Sendable {
    public struct DownloadResult: Sendable {
        public var packageDirectory: URL
        public var versionName: String
        public var fileCount: Int
    }

    public static let packageName = "com.mojang.minecraftpe"
    public init() {}

    public static func sapisidHash(sapisid: String, origin: String = "https://android.clients.google.com") -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let raw = "\(ts) \(sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hex)"
    }

    private func cookieHeader(_ auth: DeliveryAuth) -> String {
        auth.cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    public func resolveDelivery(auth: DeliveryAuth) async throws -> (versionName: String, urls: [URL], diagnostics: String) {
        guard !auth.cookies.isEmpty else {
            throw HarborError.reauthenticationRequired(providerID: .googlePlay)
        }
        let cookie = cookieHeader(auth)
        var diag: [String] = []
        diag.append("cookies=\(auth.cookies.keys.sorted().joined(separator: ","))")

        var headers: [String: String] = [
            "Cookie": cookie,
            "User-Agent": "com.android.vending/37.0.13-29 [0] [PR] 538703709 (arm64-v8a) (29)",
            "Accept-Language": "en-US,en;q=0.9",
            "X-DFE-Device-Id": deviceAndroidID,
            "X-DFE-Client-Id": "am-android-google",
            "X-DFE-SmallestScreenWidthDp": "411",
            "X-DFE-MCCMNC": "310260",
        ]
        if let sapisid = auth.cookies["SAPISID"] ?? auth.cookies["__Secure-3PSID"] ?? auth.cookies["SID"] {
            if auth.cookies["SAPISID"] != nil {
                headers["Authorization"] = Self.sapisidHash(sapisid: auth.cookies["SAPISID"]!)
            }
        }

        // Details page (browser session)
        var versionHint = "unknown"
        if let detailsURL = URL(string: "https://play.google.com/store/apps/details?id=\(Self.packageName)&hl=en&gl=US") {
            var req = URLRequest(url: detailsURL)
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                diag.append("details HTTP \(code) bytes=\(data.count)")
                let html = String(decoding: data, as: UTF8.self)
                if let v = Self.firstMatch(in: html, pattern: "\\[\\[\\[\"([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)\"") {
                    versionHint = v
                    diag.append("version=\(v)")
                }
                if html.contains("Sign in") && html.contains("accounts.google.com") {
                    diag.append("details page looks signed-out")
                }
            } catch {
                diag.append("details error \(error.localizedDescription)")
            }
        }

        // Android delivery endpoint
        var components = URLComponents(string: "https://android.clients.google.com/fdfe/delivery")!
        components.queryItems = [
            URLQueryItem(name: "doc", value: Self.packageName),
            URLQueryItem(name: "ot", value: "1"),
            URLQueryItem(name: "vc", value: "0"),
        ]
        guard let deliveryURL = components.url else {
            throw HarborError.providerFailure(reason: "Bad delivery URL")
        }
        var req = URLRequest(url: deliveryURL)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw HarborError.networkFailure(reason: "Play delivery network error: \(error.localizedDescription) | \(diag.joined(separator: "; "))")
        }
        guard let http = response as? HTTPURLResponse else {
            throw HarborError.networkFailure(reason: "No HTTP response | \(diag.joined(separator: "; "))")
        }
        diag.append("delivery HTTP \(http.statusCode) bytes=\(data.count)")
        if http.statusCode == 401 || http.statusCode == 403 {
            throw HarborError.reauthenticationRequired(providerID: .googlePlay)
        }
        if http.statusCode == 400 || http.statusCode >= 400 {
            // Fallback: try play.googleapis web gateway
            if let alt = URL(string: "https://play.googleapis.com/fdfe/delivery?doc=\(Self.packageName)&ot=1") {
                var altReq = URLRequest(url: alt)
                for (k, v) in headers { altReq.setValue(v, forHTTPHeaderField: k) }
                if let (altData, altResp) = try? await URLSession.shared.data(for: altReq),
                   let altHTTP = altResp as? HTTPURLResponse,
                   altHTTP.statusCode < 400 {
                    let urls = Self.extractURLs(altData)
                    diag.append("gateway HTTP \(altHTTP.statusCode) urls=\(urls.count)")
                    if !urls.isEmpty { return (versionHint, urls, diag.joined(separator: "; ")) }
                } else {
                    diag.append("gateway failed")
                }
            }
            throw HarborError.providerFailure(
                reason: "Play delivery rejected (HTTP \(http.statusCode)). Google often blocks unofficial clients. \(diag.joined(separator: "; "))"
            )
        }

        let urls = Self.extractURLs(data)
        diag.append("urls=\(urls.count)")
        guard !urls.isEmpty else {
            throw HarborError.providerFailure(
                reason: "Play returned no package URLs. \(diag.joined(separator: "; "))"
            )
        }
        return (versionHint, urls, diag.joined(separator: "; "))
    }

    public func downloadPackage(auth: DeliveryAuth, into stagingRoot: URL) async throws -> DownloadResult {
        let resolved = try await resolveDelivery(auth: auth)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let cookie = cookieHeader(auth)
        var saved: [URL] = []
        var index = 0
        for url in resolved.urls.prefix(8) {
            var req = URLRequest(url: url)
            if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            req.setValue("com.android.vending/37.0.13-29 [0] [PR] 538703709", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode >= 400 { continue }
                }
                if data.count < 2048 { continue }
                // APK starts with PK
                if data.count > 4, !(data[0] == 0x50 && data[1] == 0x4B) { continue }
                index += 1
                let fileURL = stagingRoot.appendingPathComponent("play-part-\(index).apk")
                try data.write(to: fileURL)
                saved.append(fileURL)
            } catch {
                continue
            }
        }
        guard !saved.isEmpty else {
            throw HarborError.invalidPackage(
                reason: "Play download produced no APK files. Diagnostics: \(resolved.diagnostics)"
            )
        }
        return DownloadResult(packageDirectory: stagingRoot, versionName: resolved.versionName, fileCount: saved.count)
    }

    private static func extractURLs(_ data: Data) -> [URL] {
        var urls: [URL] = []
        let text = String(decoding: data, as: UTF8.self)
        if let regex = try? NSRegularExpression(pattern: #"https://[^\s\"'<>]+"#, options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range).prefix(30) {
                guard let r = Range(match.range, in: text) else { continue }
                let s = String(text[r])
                if s.contains(".apk") || s.contains("play") || s.contains("googleusercontent") || s.contains("ggpht") {
                    if let url = URL(string: s) { urls.append(url) }
                }
            }
        }
        return Array(Set(urls))
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    public var deviceAndroidID: String {
        if let existing = UserDefaults.standard.string(forKey: "com.bedrockharbor.androidid"), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let id = bytes.map { String(format: "%016x", $0) }.joined().prefix(16).uppercased()
        UserDefaults.standard.set(String(id), forKey: "com.bedrockharbor.androidid")
        return String(id)
    }
}
