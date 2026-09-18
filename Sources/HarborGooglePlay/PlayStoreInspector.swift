import Foundation
import HarborDomain

/// Reads the signed-in Play Store listing for Minecraft (ownership, price, version).
public struct PlayStoreInspector: Sendable {
    public struct Listing: Sendable {
        public var versionName: String?
        public var showsBuy: Bool
        public var showsOwned: Bool
        public var priceSnippet: String?
        public var installOnDevices: Bool
        public var summary: String
    }

    public static let detailsURL = URL(string: "https://play.google.com/store/apps/details?id=com.mojang.minecraftpe&hl=en&gl=US")!

    public init() {}

    public func inspect(auth: DeliveryAuth) async -> Listing {
        var req = URLRequest(url: Self.detailsURL)
        let cookie = auth.cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let html = String(decoding: data, as: UTF8.self)
            return parse(html: html)
        } catch {
            return Listing(
                versionName: nil,
                showsBuy: false,
                showsOwned: false,
                priceSnippet: nil,
                installOnDevices: false,
                summary: "Could not read Play Store listing: \(error.localizedDescription)"
            )
        }
    }

    public func parse(html: String) -> Listing {
        var version: String?
        if let regex = try? NSRegularExpression(pattern: "\\[\\[\\[\"([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)\""),
           let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
           let r = Range(m.range(at: 1), in: html) {
            version = String(html[r])
        }
        let lower = html.lowercased()
        let installDevices = html.contains("Install on more devices")
        let uninstalledOwned = installDevices || lower.contains("you own this app")
        let pageBuyCTA = !uninstalledOwned && (html.contains("\"Buy\"") || html.contains("$6.99") || html.contains("$7.99"))
        // "Install on more devices" on the app listing is a strong ownership signal.
        let owned = uninstalledOwned
        let buy = pageBuyCTA
        var price: String?
        if let regex = try? NSRegularExpression(pattern: "\\[\\[(\\d+),\"USD\",\"(\\$[0-9.]+)\"\\]"),
           let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
           let r = Range(m.range(at: 2), in: html) {
            price = String(html[r])
        }

        var summary: String
        if owned {
            summary = "Play: this account can install Minecraft on more devices (ownership signal). Version \(version ?? "?"). Google still blocks unofficial APK delivery (DF-DFERH-01)."
        } else if buy {
            summary = "Play listing: purchase CTA\(price.map { " (\($0))" } ?? "") on this session"
        } else {
            summary = "Play listing loaded (version \(version ?? "unknown"))"
        }

        return Listing(
            versionName: version,
            showsBuy: buy && !owned,
            showsOwned: owned,
            priceSnippet: price,
            installOnDevices: installDevices,
            summary: summary
        )
    }
}
