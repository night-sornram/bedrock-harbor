import Testing
import Foundation
@testable import HarborPlatform
import HarborDomain

@Suite("Platform primitives")
struct PlatformTests {
    @Test func redactorMasksTokensURLsAndHomePaths() {
        let redactor = LogRedactor(
            homeDirectoryPath: "/Users/alice",
            managedRootPaths: ["/Users/alice/Library/Application Support/BedrockHarbor"]
        )
        let sample = """
        Authorization: Bearer abc.def.ghi
        home=/Users/alice/Library/Application Support/BedrockHarbor/Metadata
        other=/Users/alice/Documents/secret.txt
        url=https://play.googleapis.com/x?token=SECRET123&sig=abc
        contact=user@example.com
        """
        let redacted = redactor.redact(sample)
        #expect(!redacted.contains("abc.def.ghi"))
        #expect(!redacted.contains("SECRET123"))
        #expect(!redacted.contains("/Users/alice/Library"))
        #expect(redacted.contains("~/Documents"))
        #expect(redacted.contains("<BH_ROOT>"))
        #expect(redacted.contains("<ACCOUNT>"))
        #expect(redacted.contains("<REDACTED>"))
    }

    @Test func archivePolicyRejectsTraversalAbsoluteAndSymlinks() {
        #expect(ArchivePathPolicy.evaluateEntryPath("../etc/passwd").isAccepted == false)
        #expect(ArchivePathPolicy.evaluateEntryPath("/etc/passwd").isAccepted == false)
        #expect(ArchivePathPolicy.evaluateEntryPath("foo/../../bar").isAccepted == false)
        #expect(ArchivePathPolicy.evaluateEntryPath("worlds/level.dat").isAccepted)
        #expect(ArchivePathPolicy.evaluateEntryPath("evil", allowSymlink: false, isSymlink: true).isAccepted == false)
        #expect(ArchivePathPolicy.evaluateEntryPath("a/b", allowSymlink: true, isSymlink: true).isAccepted)
        #expect(ArchivePathPolicy.evaluateEntryPath("C:/windows").isAccepted == false)
        #expect(ArchivePathPolicy.evaluateEntryPath("file\0name").isAccepted == false)
    }

    @Test func archivePolicyDetectsCaseCollisions() {
        let collisions = ArchivePathPolicy.detectCollisions(paths: [
            "worlds/Level.dat",
            "worlds/level.dat",
            "worlds/other.dat",
        ])
        #expect(collisions.contains("worlds/level.dat"))
    }

    @Test func sha256OfKnownValue() {
        let hash = Hashing.sha256Hex(of: Data("abc".utf8))
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func metadataStoreRoundTripsProfiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONMetadataStore(directory: dir)
        let profile = Profile(name: "Alpha")
        try store.write([profile], fileName: "profiles.json")
        let loaded = try store.read([Profile].self, fileName: "profiles.json")
        #expect(loaded?.count == 1)
        #expect(loaded?.first?.name == "Alpha")
        #expect(loaded?.first?.dataRootID.isEmpty == false)
    }

    @Test func keychainReferenceIsOpaque() {
        let reference = CredentialReference(
            accountID: UUID(),
            purpose: .storeSession,
            key: "play-session"
        )
        #expect(reference.opaqueDescription.contains("storeSession"))
        #expect(!reference.opaqueDescription.contains("Bearer"))
    }

    @Test func inMemoryCredentialStoreRoundTrip() async throws {
        let store = InMemoryCredentialStore()
        let reference = CredentialReference(accountID: UUID(), purpose: .storeRefresh, key: "k")
        try await store.store(secret: Data("secret".utf8), for: reference)
        let value = try await store.retrieve(for: reference)
        #expect(String(data: value, encoding: .utf8) == "secret")
        try await store.delete(for: reference)
        await #expect(throws: HarborError.self) {
            _ = try await store.retrieve(for: reference)
        }
    }

    @Test func dataRootLeaseBlocksSecondOwner() async throws {
        let leases = DataRootLeaseCenter()
        try await leases.acquire(dataRootID: "root-1", owner: "launch-a")
        #expect(await leases.isHeld(dataRootID: "root-1"))
        await #expect(throws: HarborError.self) {
            try await leases.acquire(dataRootID: "root-1", owner: "backup-b")
        }
        await leases.release(dataRootID: "root-1", owner: "launch-a")
        #expect(await leases.isHeld(dataRootID: "root-1") == false)
        try await leases.acquire(dataRootID: "root-1", owner: "backup-b")
    }

    @Test func pathsLayoutUsesBundledRoots() {
        let paths = HarborPaths(
            applicationSupportRoot: URL(fileURLWithPath: "/tmp/BH-Support"),
            cachesRoot: URL(fileURLWithPath: "/tmp/BH-Caches"),
            logsRoot: URL(fileURLWithPath: "/tmp/BH-Logs")
        )
        #expect(paths.profileDataURL(dataRootID: "abc").path.hasSuffix("GameData/abc/games/com.mojang"))
        #expect(paths.metadataDirectory.lastPathComponent == "Metadata")
        #expect(paths.stagingCache.lastPathComponent == "Staging")
    }
}
