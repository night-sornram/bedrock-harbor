import AppKit
import Foundation
import HarborDomain
import HarborGooglePlay
import SwiftUI
import WebKit

/// Real Google sign-in window (WKWebView).
/// After Google login the browser often continues to play.google.com — that is expected.
/// Harbor treats that as sign-in complete and returns you to the app.
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

    private var window: NSWindow?
    private weak var webView: WKWebView?

    public static let startURL = URL(string: "https://accounts.google.com/ServiceLogin?service=androiddeveloper&continue=https%3A%2F%2Fplay.google.com%2Fstore&hl=en")!

    public func present() {
        lastError = nil
        didFinish = false
        reachedPlayStore = false
        signedInEmail = nil
        status = "Loading Google sign-in…"
        isPresented = true

        // Persistent store so Play download can reuse the Google session cookies.
        let store = WKWebsiteDataStore.default()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 560), configuration: config)
        webView.navigationDelegate = Bridge(owner: self)
        self.webView = webView
        webView.load(URLRequest(url: Self.startURL))

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
        let header = NSTextField(labelWithString: "Sign in with Google — use the account that owns Minecraft")
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

        let hint = NSTextField(labelWithString: "If you land on Play Store after login, that is normal — click Done.")
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
    }

    @objc private func doneTapped() {
        finish(email: signedInEmail)
    }

    public func dismiss() {
        window?.orderOut(nil)
        isPresented = false
    }

    fileprivate func noteNavigation(url: URL?) {
        guard let url else { return }
        let host = url.host?.lowercased() ?? ""
        status = "Page: \(host.isEmpty ? url.absoluteString : host)"
        refreshStatusLabels()

        if host.hasSuffix("play.google.com") {
            reachedPlayStore = true
            status = "Play Store opened — sign-in looks complete. Click Done to return to Harbor."
            refreshStatusLabels()
            // Auto-complete after landing on Play Store (normal Google continue URL).
            extractEmailThenFinish()
        }
    }

    private func extractEmailThenFinish() {
        webView?.evaluateJavaScript(
            """
            (function(){
              try {
                var t = document.title || '';
                var m = document.body ? (document.body.innerText || '') : '';
                var re = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/ig;
                var s = (t + '\\n' + m).match(re);
                return s && s.length ? s[0] : null;
              } catch (e) { return null; }
            })();
            """
        ) { [weak self] result, _ in
            guard let self else { return }
            Task { @MainActor in
                var email = (result as? String).flatMap { $0.contains("@") ? $0 : nil }
                if email == nil { email = self.signedInEmail ?? "Google Play account" }
                self.signedInEmail = email
                await self.captureCookiesAndFinish(email: email)
            }
        }
    }

    /// Persist Google cookies for Play Store download.
    private func captureCookiesAndFinish(email: String?) async {
        var bag: [String: String] = [:]
        if let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies() as [HTTPCookie]? {
            for cookie in cookies where cookie.domain.contains("google.com") || cookie.domain.contains("play.google.com") {
                bag[cookie.name] = cookie.value
            }
        }
        PlaySessionStore.save(cookies: bag, email: email)
        finish(email: email)
    }

    fileprivate func noteFail(message: String) {
        lastError = message
        status = message
        refreshStatusLabels()
    }

    public func finish(email: String?) {
        if let email, email.contains("@") {
            signedInEmail = email
        } else {
            signedInEmail = signedInEmail ?? "Google Play account"
        }
        status = "Signed in as \(signedInEmail ?? "Google Play account")"
        didFinish = true
        refreshStatusLabels()
        // Always persist Play cookies before signaling completion.
        Task { @MainActor in
            var bag: [String: String] = [:]
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            for cookie in cookies {
                let host = cookie.domain.lowercased()
                if host.contains("google.com") || host.contains("play.google.com") || host.contains("googleapis.com") {
                    bag[cookie.name] = cookie.value
                }
            }
            PlaySessionStore.save(cookies: bag, email: self.signedInEmail)
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            owner?.noteNavigation(url: webView.url)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                owner?.noteNavigation(url: url)
            }
            decisionHandler(.allow)
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
