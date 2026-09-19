import AppKit
import Foundation
import HarborDomain
import HarborGooglePlay
import SwiftUI
import WebKit

/// Real Google sign-in window (WKWebView) for Path A Android setup.
/// Completes only when a Play client token (oauth_token) is captured, not on website login alone.
@MainActor
@Observable
public final class GoogleSignInController {
    public static let shared = GoogleSignInController()

    public private(set) var isPresented = false
    public private(set) var status = ""
    public private(set) var signedInEmail: String?
    public private(set) var didFinish = false
    public private(set) var lastError: String?
    public private(set) var reachedPlayStore = false
    public private(set) var capturedOAuthToken = false

    private var window: NSWindow?
    private weak var webView: WKWebView?
    private var navigationBridge: Bridge?
    private var harvestTimer: Timer?
    private var freshLogin = false

    public static let startURL = URL(string: "https://accounts.google.com/embedded/setup/v2/android?source=com.android.settings&xoauth_display_name=Android%20Phone&canFrp=1&canSk=1&lang=en&langCountry=en_us&hl=en-US&cc=us")!

    public func present(freshLogin: Bool = false) {
        self.freshLogin = freshLogin
        lastError = nil
        didFinish = false
        reachedPlayStore = false
        signedInEmail = HarborPlayTokenBridge.loadAccountEmail()
        capturedOAuthToken = HarborPlayTokenBridge.loadOAuthToken() != nil
        status = freshLogin ? "Clearing Google session for a fresh Android setup…" : "Loading Google sign-in…"
        isPresented = true

        let store = WKWebsiteDataStore.default()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store

        if freshLogin {
            HarborPlayTokenBridge.clearOAuthToken()
            Task { @MainActor in
                await Self.clearGoogleCookies(store: store)
            }
        } else {
            // WKWebView's store does not reliably persist between window/app
            // sessions here — restore the harvested Google session ourselves
            // so a re-opened window resumes the Android setup instead of
            // asking for the password again.
            Task { @MainActor in
                await Self.restoreGoogleCookies(store: store)
            }
        }

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 560), configuration: config)
        // WKNavigationDelegate is weak — keep the bridge alive on the controller.
        let bridge = Bridge(owner: self)
        navigationBridge = bridge
        webView.navigationDelegate = bridge
        self.webView = webView
        // Small delay so cookie restore/clear lands before the first request.
        let delay: TimeInterval = 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isPresented, !self.didFinish else { return }
            webView.load(URLRequest(url: Self.startURL))
        }

        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Sign in with Google Play"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.center()
            window = panel
        }
        guard let window else { return }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        let header = NSTextField(labelWithString: "Sign in with Google — account that owns Minecraft")
        header.font = .boldSystemFont(ofSize: 13)
        header.frame = NSRect(x: 16, y: 680, width: 500, height: 20)
        header.autoresizingMask = [.width]

        let statusField = NSTextField(labelWithString: status)
        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        statusField.frame = NSRect(x: 16, y: 658, width: 500, height: 18)
        statusField.autoresizingMask = [.width]
        statusField.identifier = NSUserInterfaceItemIdentifier("bh.signin.status")

        webView.frame = NSRect(x: 12, y: 56, width: 516, height: 590)
        webView.autoresizingMask = [.width, .height]

        let done = NSButton(title: "Done — back to BedrockHarbor", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 280, y: 12, width: 240, height: 32)
        done.autoresizingMask = [.minXMargin, .maxYMargin]

        let hint = NSTextField(labelWithString: "Finish Android setup (I agree) until status shows oauth_token.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 20, width: 260, height: 28)
        hint.autoresizingMask = [.maxYMargin]

        root.addSubview(header)
        root.addSubview(statusField)
        root.addSubview(webView)
        root.addSubview(done)
        root.addSubview(hint)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStatusLabels()
        startHarvestTimer()
    }

    @objc private func doneTapped() {
        finish(email: signedInEmail, userInitiated: true)
    }

    public func dismiss() {
        harvestTimer?.invalidate()
        harvestTimer = nil
        window?.orderOut(nil)
        isPresented = false
    }

    private static func clearGoogleCookies(store: WKWebsiteDataStore) async {
        let cookies = await store.httpCookieStore.allCookies()
        for cookie in cookies where cookie.domain.lowercased().contains("google") {
            await store.httpCookieStore.deleteCookie(cookie)
        }
        PlaySessionStore.save(cookies: [:], email: nil)
    }

    /// Put the persisted Google session back into the webview cookie store
    /// (keyed by name only — the critical session cookies are all .google.com).
    private static func restoreGoogleCookies(store: WKWebsiteDataStore) async {
        let bag = PlaySessionStore.load().cookies
        guard !bag.isEmpty else { return }
        for (name, value) in bag where !name.hasPrefix("__Host") {
            guard let cookie = HTTPCookie(properties: [
                .domain: ".google.com",
                .path: "/",
                .name: name,
                .value: value,
                .secure: name.hasPrefix("__Secure"),
            ]) else { continue }
            await store.httpCookieStore.setCookie(cookie)
        }
    }

    private func startHarvestTimer() {
        harvestTimer?.invalidate()
        harvestTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPresented, !self.didFinish else { return }
                await self.harvestAndroidSetupCookies()
                await self.scrapePageIdentity()
            }
        }
    }

    fileprivate func noteNavigation(url: URL?) {
        guard let url else { return }
        let host = url.host?.lowercased() ?? ""
        status = "Page: \(host.isEmpty ? url.absoluteString : host)"
        refreshStatusLabels()

        // URL params are not a completion signal: Google's setup flow can carry
        // oauth_token-shaped params before login finishes. Only the oauth_token
        // cookie (harvestAndroidSetupCookies) proves the setup completed.
        if host.contains("google.com") {
            Task { await self.harvestAndroidSetupCookies(); await self.scrapePageIdentity() }
        }

        if host.hasSuffix("play.google.com") {
            reachedPlayStore = true
            status = "Play Store opened — harvesting credentials…"
            refreshStatusLabels()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.didFinish else { return }
                Task { await self.harvestAndroidSetupCookies(); await self.scrapePageIdentity() }
            }
        }
    }

    /// Collect oauth_token / Email / user_id from Android embedded setup cookies.
    private func harvestAndroidSetupCookies() async {
        var oauth: String?
        var email: String?
        var userID = ""
        var bag: [String: String] = [:]
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies {
            let host = cookie.domain.lowercased()
            guard host.contains("google.com") || host.contains("play.google.com") else { continue }
            bag[cookie.name] = cookie.value
            if cookie.name == "oauth_token", !cookie.value.isEmpty, cookie.value != oauth {
                oauth = cookie.value
            }
            if (cookie.name == "Email" || cookie.name == "email"), cookie.value.contains("@") {
                email = cookie.value
            }
            if cookie.name == "user_id", !cookie.value.isEmpty { userID = cookie.value }
        }
        if let oauth {
            HarborPlayTokenBridge.saveOAuthToken(oauth)
            PlayCredentialBackup.save(oauth: oauth, email: email)
            capturedOAuthToken = true
            status = "Captured oauth_token (\(oauth.prefix(12))…)"
            refreshStatusLabels()
        }
        if let email {
            signedInEmail = email
            HarborPlayTokenBridge.saveAccountEmail(email)
            if oauth == nil {
                status = "Account \(email) — still waiting for oauth_token"
            } else if status.isEmpty || status.hasPrefix("Page:") {
                status = "Account \(email) + oauth_token"
            }
            refreshStatusLabels()
        }
        if !userID.isEmpty, bag["user_id"] == nil {
            bag["user_id"] = userID
        }
        if !bag.isEmpty {
            PlaySessionStore.save(cookies: bag, email: email ?? signedInEmail)
        }
        // Path A is complete ONLY when the oauth_token cookie was harvested —
        // not when any token-shaped value appeared in a URL or the page.
        if oauth != nil, !didFinish {
            finish(email: email ?? signedInEmail, userInitiated: false)
        }
    }

    private func scrapePageIdentity() async {
        guard let webView else { return }
        let js = """
        (function(){
          try {
            var blob = (document.title || '') + '\\n' + (document.body ? (document.body.innerText || '') : '') + '\\n' + (document.documentElement ? (document.documentElement.innerHTML || '') : '');
            var emailRe = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/ig;
            var emails = blob.match(emailRe) || [];
            var preferred = null;
            for (var i = 0; i < emails.length; i++) {
              var e = emails[i];
              if (/@(gmail|googlemail)\\.com$/i.test(e) || /@(google)\\.com$/i.test(e)) { preferred = e; break; }
            }
            if (!preferred && emails.length) preferred = emails[0];
            var token = null;
            var m = blob.match(/oauth_token=([A-Za-z0-9_\\-\\.\\/]{20,})/);
            if (m) token = m[1];
            var ya = blob.match(/ya29\\.[A-Za-z0-9_\\-\\.]{20,}/);
            if (!token && ya) token = ya[0];
            var oauth2 = blob.match(/oauth2_[0-9]+\\/[A-Za-z0-9_\\-\\.]{20,}/);
            if (!token && oauth2) token = oauth2[0];
            return { email: preferred, token: token };
          } catch (e) { return null; }
        })();
        """
        let result = try? await webView.evaluateJavaScript(js)
        if let dict = result as? [String: Any] {
            // Email only — tokens scraped from page content are not trustworthy
            // completion signals; only the oauth_token cookie is.
            if let email = dict["email"] as? String, email.contains("@") {
                signedInEmail = email
                HarborPlayTokenBridge.saveAccountEmail(email)
                PlaySessionStore.save(cookies: PlaySessionStore.load().cookies, email: email)
            }
        } else if let email = result as? String, email.contains("@") {
            signedInEmail = email
            HarborPlayTokenBridge.saveAccountEmail(email)
        }
        refreshStatusLabels()
    }

    fileprivate func noteFail(message: String) {
        lastError = message
        status = message
        refreshStatusLabels()
    }

    public func finish(email: String?, userInitiated: Bool = true) {
        var resolvedEmail = email
        if resolvedEmail == nil || !(resolvedEmail?.contains("@") ?? false) {
            resolvedEmail = HarborPlayTokenBridge.loadAccountEmail()
        }
        if resolvedEmail == nil || !(resolvedEmail?.contains("@") ?? false) {
            resolvedEmail = signedInEmail
        }
        if let resolvedEmail, resolvedEmail.contains("@") {
            signedInEmail = resolvedEmail
            HarborPlayTokenBridge.saveAccountEmail(resolvedEmail)
        }

        let token = HarborPlayTokenBridge.loadOAuthToken()
            ?? PlaySessionStore.load().cookies["oauth_token"]
        if let token {
            HarborPlayTokenBridge.saveOAuthToken(token)
            PlayCredentialBackup.save(oauth: token, email: resolvedEmail)
            capturedOAuthToken = true
        }

        if token == nil && userInitiated {
            status = "oauth_token not captured yet — finish Android setup (I agree), then Done"
            lastError = status
            refreshStatusLabels()
            // Still return control, but do not claim success.
            didFinish = true
            dismiss()
            NotificationCenter.default.post(name: .bhGoogleSignInFinished, object: self)
            return
        }

        if token != nil {
            status = "Play token ready\(resolvedEmail.map { " as \($0)" } ?? "")"
        } else {
            status = "Signed in as \(resolvedEmail ?? "Google Play account") — no oauth_token"
        }
        didFinish = true
        refreshStatusLabels()
        Task { @MainActor in
            var bag: [String: String] = [:]
            var oauth: String?
            var email = self.signedInEmail
            var userID = ""
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            for cookie in cookies {
                let host = cookie.domain.lowercased()
                if !(host.contains("google.com") || host.contains("play.google.com") || host.contains("googleapis.com")) { continue }
                bag[cookie.name] = cookie.value
                if cookie.name == "oauth_token", !cookie.value.isEmpty { oauth = cookie.value }
                if (cookie.name == "Email" || cookie.name == "email"), cookie.value.contains("@") { email = cookie.value }
                if cookie.name == "user_id", !cookie.value.isEmpty { userID = cookie.value }
            }
            if let oauth {
                HarborPlayTokenBridge.saveOAuthToken(oauth)
            }
            if let email {
                HarborPlayTokenBridge.saveAccountEmail(email)
            }
            if !userID.isEmpty { bag["user_id"] = userID }
            PlaySessionStore.save(cookies: bag, email: email)
            self.dismiss()
            NotificationCenter.default.post(name: .bhGoogleSignInFinished, object: self)
        }
    }

    private func refreshStatusLabels() {
        guard let root = window?.contentView else { return }
        for sub in root.subviews {
            if let field = sub as? NSTextField, field.identifier == NSUserInterfaceItemIdentifier("bh.signin.status") {
                field.stringValue = status
            }
        }
    }

    private final class Bridge: NSObject, WKNavigationDelegate {
        weak var owner: GoogleSignInController?
        init(owner: GoogleSignInController) { self.owner = owner }

        // Navigation is observed at completion (didFinish) only, on purpose: a
        // decidePolicyFor witness fires for transient OAuth redirects too, and URLs
        // carrying access_token/token params would save a token early — the harvest
        // timer then auto-finishes the window before Android setup sets the
        // oauth_token cookie the Play download needs, forcing a second login.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            owner?.noteNavigation(url: webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            owner?.noteFail(message: error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            owner?.noteFail(message: error.localizedDescription)
        }
    }
}

extension Notification.Name {
    public static let bhGoogleSignInFinished = Notification.Name("BHGoogleSignInFinished")
}
