import AppKit
import Foundation
import HarborGooglePlay
import WebKit

/// A browser attempt only returns candidate credentials. The session coordinator
/// validates them before either screen can claim that Google Play is signed in.
@MainActor
public final class GoogleSignInController {
    public static let shared = GoogleSignInController()
    private var window: NSWindow?
    private var webView: WKWebView?
    private var bridge: Bridge?
    private var harvestTimer: Timer?
    private var timeoutTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var attemptID: UUID?
    private var completion: CheckedContinuation<GoogleSignInResult, Never>?
    private var statusField: NSTextField?

    public static let startURL = URL(string: "https://accounts.google.com/embedded/setup/v2/android?source=com.android.settings&xoauth_display_name=Android%20Phone&canFrp=1&canSk=1&lang=en&langCountry=en_us&hl=en-US&cc=us")!

    func signIn(fresh: Bool) async -> GoogleSignInResult {
        guard attemptID == nil else { return .cancelled }
        let attempt = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancelled }
            return await withCheckedContinuation { continuation in
                completion = continuation
                attemptID = attempt
                present(fresh: fresh, attempt: attempt)
            }
        } onCancel: {
            Task { @MainActor in self.complete(.cancelled, attempt: attempt) }
        }
    }

    private func present(fresh: Bool, attempt: UUID) {
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let browser = WKWebView(frame: .zero, configuration: configuration)
        let delegate = Bridge(owner: self, attempt: attempt)
        bridge = delegate
        browser.navigationDelegate = delegate
        webView = browser

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Sign in with Google Play"
        panel.isReleasedWhenClosed = false
        panel.delegate = delegate
        panel.minSize = NSSize(width: 500, height: 550)
        panel.center()
        window = panel

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 720))
        let header = NSTextField(labelWithString: "Sign in with the Google account you use for Minecraft")
        header.font = .boldSystemFont(ofSize: 13)
        header.frame = NSRect(x: 16, y: 680, width: 528, height: 20)
        header.autoresizingMask = [.width, .minYMargin]
        let status = NSTextField(labelWithString: "Loading Google sign-in…")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 16, y: 654, width: 528, height: 20)
        status.autoresizingMask = [.width, .minYMargin]
        statusField = status
        browser.frame = NSRect(x: 12, y: 60, width: 536, height: 580)
        browser.autoresizingMask = [.width, .height]
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 16, y: 16, width: 90, height: 32)
        let done = NSButton(title: "Continue", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 414, y: 16, width: 130, height: 32)
        done.autoresizingMask = [.minXMargin]
        for view in [header, status, browser, cancel, done] { root.addSubview(view) }
        panel.contentView = root
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Each attempt has its own cookie jar. Fresh sign-in cannot race a
        // delayed restoration from an earlier attempt, and cancellation never
        // persists a partially completed login.
        let saved = fresh ? [:] : PlaySessionStore.load().cookies
        preparationTask = Task { [weak self] in
            for (name, value) in saved where !name.hasPrefix("__Host") {
                guard !Task.isCancelled else { return }
                guard let cookie = HTTPCookie(properties: [
                    .domain: ".google.com", .path: "/", .name: name,
                    .value: value, .secure: "TRUE",
                ]) else { continue }
                await store.httpCookieStore.setCookie(cookie)
            }
            guard let self, attemptID == attempt, !Task.isCancelled else { return }
            browser.load(URLRequest(url: Self.startURL))
            harvestTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.harvest(attempt: attempt, userInitiated: false) }
            }
        }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self?.complete(.timedOut, attempt: attempt)
        }
    }

    @objc private func cancelTapped() { cancel() }
    @objc private func doneTapped() {
        guard let attempt = attemptID else { return }
        Task { await harvest(attempt: attempt, userInitiated: true) }
    }

    func cancel() {
        guard let attempt = attemptID else { return }
        complete(.cancelled, attempt: attempt)
    }

    private func harvest(attempt: UUID, userInitiated: Bool) async {
        guard attemptID == attempt, let webView else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard attemptID == attempt else { return }
        var bag: [String: String] = [:]
        for cookie in cookies where Self.isGoogleHost(cookie.domain) {
            if let expiry = cookie.expiresDate, expiry <= Date() { continue }
            bag[cookie.name] = cookie.value
        }
        guard let token = bag["oauth_token"], HarborPlayTokenBridge.looksLikeOAuthAccessToken(token) else {
            if userInitiated { statusField?.stringValue = "Finish Google's sign-in steps, then choose Continue." }
            return
        }
        let email = [bag["Email"], bag["email"]].compactMap { $0 }.first { $0.contains("@") }
        complete(.completed(.init(cookies: bag, email: email)), attempt: attempt)
    }

    private func complete(_ result: GoogleSignInResult, attempt: UUID) {
        guard attemptID == attempt else { return }
        attemptID = nil
        preparationTask?.cancel()
        timeoutTask?.cancel()
        harvestTimer?.invalidate()
        preparationTask = nil
        timeoutTask = nil
        harvestTimer = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        webView = nil
        bridge = nil
        statusField = nil
        let continuation = completion
        completion = nil
        continuation?.resume(returning: result)
    }

    static func isGoogleHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == "google.com" || host.hasSuffix(".google.com")
            || host == "googleapis.com" || host.hasSuffix(".googleapis.com")
    }

    static func clearSavedCookies() async {
        let store = WKWebsiteDataStore.default()
        for cookie in await store.httpCookieStore.allCookies() where isGoogleHost(cookie.domain) {
            await store.httpCookieStore.deleteCookie(cookie)
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { isGoogleHost($0.displayName) }
        await store.removeData(ofTypes: types, for: records)
    }

    private final class Bridge: NSObject, WKNavigationDelegate, NSWindowDelegate {
        weak var owner: GoogleSignInController?
        let attempt: UUID
        init(owner: GoogleSignInController, attempt: UUID) { self.owner = owner; self.attempt = attempt }

        func windowWillClose(_ notification: Notification) {
            owner?.complete(.cancelled, attempt: attempt)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await owner?.harvest(attempt: attempt, userInitiated: false) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            guard owner?.attemptID == attempt else { return }
            owner?.complete(.failed("Google sign-in could not load. Check your connection and try again."), attempt: attempt)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            self.webView(webView, didFail: navigation, withError: error)
        }
    }
}
