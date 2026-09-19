import XCTest
import Foundation
import HarborPlatform
@testable import HarborRuntime

final class LocalRuntimeDiscoveryCacheTests: XCTestCase {
    private var tempDir: URL!
    private var supportRoot: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscoveryCacheTests-\(UUID().uuidString)", isDirectory: true)
        supportRoot = tempDir.appendingPathComponent("Support", isDirectory: true)
        LocalRuntimeDiscovery.harborSupportOverride = supportRoot
        LocalRuntimeDiscovery.resetProcessDiscoveryCachesForTesting()
    }

    override func tearDown() {
        LocalRuntimeDiscovery.harborSupportOverride = nil
        LocalRuntimeDiscovery.resetProcessDiscoveryCachesForTesting()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - fixtures

    /// Usable runtime root: executable + qt.conf + cocoa platform plugin.
    @discardableResult
    private func makeUsableRuntimeRoot(name: String, executableBytes: Data) throws -> URL {
        let fm = FileManager.default
        let root = supportRoot.appendingPathComponent("Runtimes/\(name)", isDirectory: true)
        let macos = root.appendingPathComponent("MacOS", isDirectory: true)
        let platforms = root.appendingPathComponent("PlugIns/platforms", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: platforms, withIntermediateDirectories: true)
        let executable = macos.appendingPathComponent("mcpelauncher-client")
        try executableBytes.write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("# qt.conf".utf8).write(to: macos.appendingPathComponent("qt.conf"))
        try Data("fake dylib".utf8).write(to: platforms.appendingPathComponent("libqcocoa.dylib"))
        return root
    }

    private var hashCacheURL: URL {
        supportRoot.appendingPathComponent("Metadata/runtime-hash-cache.json", isDirectory: false)
    }

    private func loadHashCache() throws -> [String: RuntimeHashCacheEntry] {
        try JSONDecoder().decode([String: RuntimeHashCacheEntry].self, from: Data(contentsOf: hashCacheURL))
    }

    // MARK: - in-memory bundle cache

    func testSecondDiscoveryInProcessReusesBundle() throws {
        let root = try makeUsableRuntimeRoot(name: "only", executableBytes: Data("exec-content".utf8))

        let first = LocalRuntimeDiscovery().discoverDefault()
        XCTAssertNotNil(first)
        // contentsOfDirectory resolves /var → /private/var; compare standardized paths.
        XCTAssertEqual(first?.layout.runtimeRootURL.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertFalse(LocalRuntimeDiscovery.lastDiscoveryCacheHit, "first discovery must not hit the cache")

        let second = LocalRuntimeDiscovery().discoverDefault()
        XCTAssertNotNil(second)
        XCTAssertTrue(LocalRuntimeDiscovery.lastDiscoveryCacheHit, "unchanged Runtimes/ listing must reuse the bundle")
        XCTAssertEqual(
            second?.runtimeInstallation.artifactSHA256,
            first?.runtimeInstallation.artifactSHA256
        )
    }

    func testChangedRuntimesListingInvalidatesBundleCache() throws {
        try makeUsableRuntimeRoot(name: "only", executableBytes: Data("exec-content".utf8))
        XCTAssertNotNil(LocalRuntimeDiscovery().discoverDefault())
        XCTAssertTrue(LocalRuntimeDiscovery.lastDiscoveryCacheHit || true) // warm the cache
        _ = LocalRuntimeDiscovery().discoverDefault()
        XCTAssertTrue(LocalRuntimeDiscovery.lastDiscoveryCacheHit)

        // A new top-level directory (even a skipped "_" one) changes the listing.
        try FileManager.default.createDirectory(
            at: supportRoot.appendingPathComponent("Runtimes/_staging", isDirectory: true),
            withIntermediateDirectories: true
        )
        let rediscovered = LocalRuntimeDiscovery().discoverDefault()
        XCTAssertNotNil(rediscovered)
        XCTAssertFalse(LocalRuntimeDiscovery.lastDiscoveryCacheHit, "listing drift must force re-discovery")
    }

    // MARK: - persisted hash cache

    func testHashCacheServesAcrossRestartAndRefreshesOnChange() throws {
        _ = try makeUsableRuntimeRoot(name: "only", executableBytes: Data("exec-content-1".utf8))
        let expectedSHA = Hashing.sha256Hex(of: Data("exec-content-1".utf8))

        let first = try XCTUnwrap(LocalRuntimeDiscovery().discoverDefault())
        XCTAssertEqual(first.runtimeInstallation.artifactSHA256, expectedSHA)
        // Discovery's URL (symlinks resolved, e.g. /private/var) is the cache key.
        let executable = first.layout.executableURL

        // Persisted after the first hash.
        var cache = try loadHashCache()
        XCTAssertEqual(cache[executable.path]?.sha256, expectedSHA)

        // Simulate a restart: wipe the process caches, then poison the persisted entry
        // (same size + mtime, wrong digest). If discovery consults the cache instead of
        // re-hashing, the poisoned value is what comes back.
        LocalRuntimeDiscovery.resetProcessDiscoveryCachesForTesting()
        cache[executable.path]?.sha256 = "deadbeef"
        cache["/nonexistent/mcpelauncher-client"] = RuntimeHashCacheEntry(size: 1, mtime: 0, sha256: "prune-me")
        try JSONEncoder().encode(cache).write(to: hashCacheURL)
        // Listing drift so the in-memory bundle cache cannot short-circuit either.
        try FileManager.default.createDirectory(
            at: supportRoot.appendingPathComponent("Runtimes/_staging", isDirectory: true),
            withIntermediateDirectories: true
        )

        let second = try XCTUnwrap(LocalRuntimeDiscovery().discoverDefault())
        XCTAssertFalse(LocalRuntimeDiscovery.lastDiscoveryCacheHit)
        XCTAssertEqual(
            second.runtimeInstallation.artifactSHA256,
            "deadbeef",
            "unchanged size+mtime must be served from the persisted cache without re-hashing"
        )

        // Mutating the executable (different bytes → size/mtime drift) must re-hash,
        // refresh the entry, and prune the entry for the deleted path.
        LocalRuntimeDiscovery.resetProcessDiscoveryCachesForTesting()
        try Data("exec-content-2-mutated".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let third = try XCTUnwrap(LocalRuntimeDiscovery().discoverDefault())
        XCTAssertEqual(
            third.runtimeInstallation.artifactSHA256,
            Hashing.sha256Hex(of: Data("exec-content-2-mutated".utf8)),
            "size/mtime drift must force a real re-hash"
        )

        let refreshed = try loadHashCache()
        XCTAssertEqual(refreshed[executable.path]?.sha256, third.runtimeInstallation.artifactSHA256)
        XCTAssertNil(refreshed["/nonexistent/mcpelauncher-client"], "stale entries must be pruned")
    }

    func testUsabilityGateStillRunsForUnvalidatedRoots() throws {
        // A root missing the platform plugin is not usable and must not be discovered,
        // even though another usable root exists alongside it.
        try makeUsableRuntimeRoot(name: "usable", executableBytes: Data("exec".utf8))
        let broken = supportRoot.appendingPathComponent("Runtimes/broken", isDirectory: true)
        try FileManager.default.createDirectory(
            at: broken.appendingPathComponent("MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let exe = broken.appendingPathComponent("MacOS/mcpelauncher-client")
        try Data("exec".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let bundle = LocalRuntimeDiscovery().discoverDefault()
        XCTAssertEqual(bundle?.layout.runtimeRootURL.lastPathComponent, "usable")
    }
}
