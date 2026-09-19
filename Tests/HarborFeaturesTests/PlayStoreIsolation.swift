import Foundation
import HarborGooglePlay
@testable import HarborFeatures

/// Process-wide test isolation for the account-adjacent stores reached from
/// `AppState` (`HarborPlayTokenBridge`, `PlaySessionStore`,
/// `PlayCredentialBackup`, and AppState's own UserDefaults reads).
///
/// Activating points all of them at a throwaway temp home plus a path-backed
/// defaults suite, so no test reads — let alone writes — the real user's
/// `~/Library/Application Support/BedrockHarbor`, `~/.bedrockharbor`, or
/// `UserDefaults.standard`. The path-backed suite keeps even the defaults
/// plist inside the temp tree (never `~/Library/Preferences`).
///
/// Activation is lazy, thread-safe (`static let`), and permanent for the
/// process: the overrides are never swapped back mid-run, so parallel tests can
/// never race a restore back to real storage. Tests that need deterministic
/// credential state reset the shared temp stores instead (see
/// `AppStateInstallGateTests.resetPlayState`) and live in a `.serialized`
/// suite.
enum PlayStoreIsolation {
    /// Shared throwaway home backing every account-adjacent store in this process.
    static let home: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-playstores-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        HarborPlayTokenBridge.homeOverride = url
        PlaySessionStore.homeOverride = url
        PlayCredentialBackup.urlOverride =
            url.appendingPathComponent(".bedrockharbor/credentials.json", isDirectory: false)
        GPlayDLClient.workDirOverride = url.appendingPathComponent("PlayAPI", isDirectory: true)
        AppState.defaultsOverride = defaults
        return url
    }()

    /// Path-backed defaults suite: persists inside the temp tree only — never
    /// touches `~/Library/Preferences` or `UserDefaults.standard`.
    /// (`nonisolated(unsafe)`: UserDefaults is not Sendable, but this static
    /// is written once during lazy init and only read afterwards.)
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-playdefaults-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("defaults.plist", isDirectory: false)
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let suite = UserDefaults(suiteName: path.path)
            ?? UserDefaults(suiteName: "bh-playdefaults-fallback-\(UUID().uuidString)")!
        HarborPlayTokenBridge.defaultsOverride = suite
        PlaySessionStore.defaultsOverride = suite
        return suite
    }()

    /// Idempotent: force both lazy statics before any AppState construction.
    static func activate() {
        _ = home
        _ = defaults
    }
}
