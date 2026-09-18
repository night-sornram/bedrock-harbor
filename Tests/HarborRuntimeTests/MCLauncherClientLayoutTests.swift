import XCTest
@testable import HarborRuntime
import HarborDomain

final class MCLauncherClientLayoutTests: XCTestCase {
    private func makeLayout() -> MCLauncherClientLayout {
        MCLauncherClientLayout(
            runtimeRootURL: URL(fileURLWithPath: "/tmp/bh-runtime", isDirectory: true),
            executableURL: URL(fileURLWithPath: "/tmp/bh-runtime/MacOS/mcpelauncher-client"),
            gameDirectoryURL: URL(fileURLWithPath: "/tmp/bh-game", isDirectory: true),
            releaseID: "harbor-mcpelauncher-test",
            versionLabel: "v1.8.4-573"
        )
    }

    /// The Xbox sign-in webview (QtWebEngine) advertises the WebAuthn/passkey API but
    /// cannot open a platform authenticator on macOS — Microsoft's "Face, fingerprint,
    /// PIN or security key" challenge then waits forever. The API must be disabled so
    /// Microsoft offers password sign-in instead.
    func testLaunchEnvironmentDisablesPasskeyInEmbeddedWebView() {
        let env = makeLayout().launchEnvironment()
        let flags = env["QTWEBENGINE_CHROMIUM_FLAGS"]
        XCTAssertNotNil(flags, "QTWEBENGINE_CHROMIUM_FLAGS must be set for the game env")
        XCTAssertTrue(
            flags?.contains("--disable-blink-features=WebAuthentication") == true,
            "WebAuthn must be disabled in the embedded webview, got: \(flags ?? "nil")"
        )
    }

    func testExplicitEnvironmentOverrideStillWins() {
        let env = makeLayout().launchEnvironment(extra: ["QTWEBENGINE_CHROMIUM_FLAGS": "--custom-flag"])
        XCTAssertEqual(env["QTWEBENGINE_CHROMIUM_FLAGS"], "--custom-flag")
    }
}
