import Foundation

// MARK: - Store & authentication

public protocol MinecraftStoreProvider: Sendable {
    var providerID: ProviderID { get }
    func capabilities() async -> ProviderCapabilities
    func listKnownVersions() async throws -> [MinecraftVersion]
    func checkEntitlement(accountID: UUID) async throws -> EntitlementResult
    /// Delivery resolution is separate from downloading.
    func resolveDelivery(
        accountID: UUID,
        buildID: MinecraftBuildID
    ) async throws -> PackageDelivery
}

public protocol AuthenticationProvider: Sendable {
    var providerID: ProviderID { get }
    func beginSignIn() async throws -> AuthSessionHandle
    func restoreSession(accountID: UUID) async throws -> AuthSessionHandle
    func refreshSession(accountID: UUID) async throws -> AuthSessionHandle
    func signOut(accountID: UUID) async throws
    /// Streams progress without exposing tokens to UI.
    func progressStream(accountID: UUID?) -> AsyncStream<AuthenticationProgress>
}

public protocol CredentialStore: Sendable {
    func store(secret: Data, for reference: CredentialReference) async throws
    func retrieve(for reference: CredentialReference) async throws -> Data
    func replace(secret: Data, for reference: CredentialReference) async throws
    func delete(for reference: CredentialReference) async throws
}

// MARK: - Downloads & installation

public protocol DownloadManaging: Sendable {
    func start(
        request: DownloadRequest,
        artifact: PackageDelivery.Artifact,
        authorizationHandle: String?
    ) async throws -> URL
    func progress(for id: UUID) -> AsyncStream<DownloadProgress>
    func cancel(id: UUID) async
}

public protocol MinecraftInstalling: Sendable {
    func validate(delivery: PackageDelivery, stagedFiles: [URL]) async throws
    func stageInstall(delivery: PackageDelivery, artifacts: [URL]) async throws -> URL
    func commit(stagingURL: URL, buildID: MinecraftBuildID, providerID: ProviderID) async throws -> InstalledMinecraft
    func remove(installationID: UUID) async throws
}

// MARK: - Runtime

public protocol RuntimeProviding: Sendable {
    func discoverInstallations() async throws -> [RuntimeInstallation]
    func approvedReleases() async throws -> [RuntimeRelease]
    func install(release: RuntimeRelease, artifactURL: URL) async throws -> RuntimeInstallation
    func health(for installationID: UUID) async throws -> RuntimeHealth
}

public protocol RuntimeLaunching: Sendable {
    func prepareLaunchPlan(
        profile: Profile,
        installation: InstalledMinecraft,
        runtime: RuntimeInstallation
    ) async throws -> LaunchPlan
    func start(plan: LaunchPlan) async throws -> LaunchSession
    func events(sessionID: UUID) -> AsyncStream<LaunchSessionState>
    func requestTermination(sessionID: UUID) async throws
}

// MARK: - Compatibility

public struct CompatibilityEnvironment: Hashable, Sendable, Codable {
    public var osVersion: String
    public var processArchitecture: String
    public var isTranslated: Bool
    public var gameBuildID: MinecraftBuildID?
    public var runtimeReleaseID: String?
    public var runtimeSHA256: String?
    public var patchIDs: [String]
    public var installationIntegrity: InstallationIntegrity

    public init(
        osVersion: String,
        processArchitecture: String,
        isTranslated: Bool = false,
        gameBuildID: MinecraftBuildID? = nil,
        runtimeReleaseID: String? = nil,
        runtimeSHA256: String? = nil,
        patchIDs: [String] = [],
        installationIntegrity: InstallationIntegrity = .unknown
    ) {
        self.osVersion = osVersion
        self.processArchitecture = processArchitecture
        self.isTranslated = isTranslated
        self.gameBuildID = gameBuildID
        self.runtimeReleaseID = runtimeReleaseID
        self.runtimeSHA256 = runtimeSHA256
        self.patchIDs = patchIDs
        self.installationIntegrity = installationIntegrity
    }
}

public protocol CompatibilityEvaluating: Sendable {
    func evaluate(environment: CompatibilityEnvironment) async throws -> CompatibilityReport
}

// MARK: - Worlds & content

public protocol WorldManaging: Sendable {
    func discoverWorlds(profile: Profile) async throws -> [WorldRecord]
    func backup(world: WorldRecord, profile: Profile) async throws -> BackupManifest
    func restoreAsNewWorld(backupID: UUID, profile: Profile) async throws -> WorldRecord
    func exportMcworld(world: WorldRecord, profile: Profile, to destination: URL) async throws
    func importMcworld(from sourceURL: URL, profile: Profile) async throws -> WorldRecord
}

public protocol ContentImporting: Sendable {
    func inspect(fileURL: URL) async throws -> ContentInspection
    func plan(inspections: [ContentInspection], profile: Profile) async throws -> ImportPlan
    func commit(plan: ImportPlan) async throws
}

public protocol DiagnosticsCollecting: Sendable {
    func collect() async throws -> DiagnosticsSnapshot
    func exportPreview() async throws -> DiagnosticsSnapshot
    func exportBundle(to destinationDirectory: URL) async throws -> URL
}

// MARK: - Metadata repository

public protocol MetadataRepository: Sendable {
    func loadProfiles() async throws -> [Profile]
    func saveProfiles(_ profiles: [Profile]) async throws
    func loadInstallations() async throws -> [InstalledMinecraft]
    func saveInstallations(_ items: [InstalledMinecraft]) async throws
    func loadAccounts() async throws -> [AccountRecord]
    func saveAccounts(_ items: [AccountRecord]) async throws
    func loadRuntimeInstallations() async throws -> [RuntimeInstallation]
    func saveRuntimeInstallations(_ items: [RuntimeInstallation]) async throws
}

// MARK: - Redaction

public protocol Redacting: Sendable {
    func redact(_ text: String) -> String
}

// MARK: - Data-root mutation lease

/// Serializes world/backup/import/launch mutations for one game-data root.
public protocol DataRootLeasing: Sendable {
    func acquire(dataRootID: String, owner: String) async throws
    func release(dataRootID: String, owner: String) async
    func isHeld(dataRootID: String) async -> Bool
}
