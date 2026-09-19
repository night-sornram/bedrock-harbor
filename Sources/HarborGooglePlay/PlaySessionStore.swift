import Foundation
import HarborDomain
import HarborPlatform
import WebKit

/// Persist Google/Play session for download. Cookies are stored both in UserDefaults
/// and a private file under Application Support so install can always re-read them.
public enum PlaySessionStore {
    private static let defaultsCookiesKey = "com.bedrockharbor.play.cookies"
    private static let defaultsEmailKey = "com.bedrockharbor.play.email"

    /// Test seam: overrides the storage home (nil in production → real home).
    nonisolated(unsafe) public static var homeOverride: URL?
    /// Test seam: overrides the defaults store (nil in production → .standard).
    nonisolated(unsafe) public static var defaultsOverride: UserDefaults?

    private static var defaults: UserDefaults { defaultsOverride ?? .standard }

    private static var fileURL: URL {
        (homeOverride ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Library/Application Support/BedrockHarbor/play-session.json", isDirectory: false)
    }

    public struct Payload: Codable, Sendable {
        public var cookies: [String: String]
        public var email: String?
        public var savedAt: Date
    }

    public static func save(cookies: [String: String], email: String?) {
        defaults.set(cookies, forKey: defaultsCookiesKey)
        if let email { defaults.set(email, forKey: defaultsEmailKey) }
        else { defaults.removeObject(forKey: defaultsEmailKey) }
        let payload = Payload(cookies: cookies, email: email, savedAt: Date())
        if let data = try? JSONEncoder().encode(payload) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public static func load() -> DeliveryAuth {
        // Prefer file (more reliable), fall back to defaults.
        if let data = try? Data(contentsOf: fileURL),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           !payload.cookies.isEmpty {
            return DeliveryAuth(cookies: payload.cookies, accountEmail: payload.email)
        }
        let cookies = defaults.dictionary(forKey: defaultsCookiesKey) as? [String: String] ?? [:]
        let email = defaults.string(forKey: defaultsEmailKey)
        return DeliveryAuth(cookies: cookies, accountEmail: email)
    }

    public static var isReady: Bool {
        !load().cookies.isEmpty
    }

    public static func clear() throws {
        defaults.removeObject(forKey: defaultsCookiesKey)
        defaults.removeObject(forKey: defaultsEmailKey)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Harvest cookies from the live WebKit store (called at install time).
    @MainActor
    public static func harvestFromWebKit(email: String?) async -> DeliveryAuth {
        var bag: [String: String] = [:]
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies {
            let host = cookie.domain.lowercased()
            if host.contains("google.com") || host.contains("play.google.com") || host.contains("googleapis.com") {
                bag[cookie.name] = cookie.value
            }
        }
        if !bag.isEmpty {
            save(cookies: bag, email: email ?? load().accountEmail)
        }
        var auth = load()
        if !bag.isEmpty {
            auth = DeliveryAuth(cookies: bag, accountEmail: email ?? auth.accountEmail)
        }
        return auth
    }

    public static var cookieSummary: String {
        let auth = load()
        if auth.cookies.isEmpty { return "0 cookies" }
        let names = auth.cookies.keys.sorted().joined(separator: ", ")
        return "\(auth.cookies.count) cookies (\(names))"
    }
}

public struct DeliveryAuth: Sendable {
    public var cookies: [String: String]
    public var accountEmail: String?
    public init(cookies: [String: String], accountEmail: String? = nil) {
        self.cookies = cookies
        self.accountEmail = accountEmail
    }
}
