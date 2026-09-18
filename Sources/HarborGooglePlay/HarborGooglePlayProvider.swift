import Foundation
import HarborDomain
import HarborPlatform

/// Independent Google Play adapter scaffold.
///
/// Implements the contract surface for authentication, entitlement, catalog, and
/// delivery resolution. Wire protocol work is intentionally incomplete until the
/// feasibility gate research produces sanitized fixtures and a tested auth contract.
///
/// Product constraints:
/// - No FinskyKit dependency
/// - No mcpelauncher-swift code copy
/// - Tokens never leave CredentialStore / this adapter's internal session actor
public struct HarborGooglePlayProvider: MinecraftStoreProvider, AuthenticationProvider, Sendable {
    public let providerID: ProviderID = .googlePlay

    private let credentials: any CredentialStore
    private let sessions: SessionRegistry
    private let policy: PlayPolicy

    public init(
        credentials: any CredentialStore,
        policy: PlayPolicy = .foundation,
        sessions: SessionRegistry = SessionRegistry()
    ) {
        self.credentials = credentials
        self.policy = policy
        self.sessions = sessions
    }

    // MARK: Store provider

    public func capabilities() async -> ProviderCapabilities {
        ProviderCapabilities(
            providerID: .googlePlay,
            supported: policy.advertisedCapabilities,
            notes: [
                "Independent adapter; protocol implementation gated on research artifacts.",
                "Store ownership is not Xbox identity.",
                "Windows/Java/iOS purchases are not interchangeable with Play entitlement.",
            ]
        )
    }

    public func listKnownVersions() async throws -> [MinecraftVersion] {
        // Foundation catalog is intentionally tiny and reviewed.
        // Do not bundle the entire upstream version database.
        FoundationCatalog.knownVersions
    }

    public func checkEntitlement(accountID: UUID) async throws -> EntitlementResult {
        try policy.requireLiveProvider()
        guard try await sessions.requireReady(accountID: accountID, credentials: credentials) != nil else {
            throw HarborError.reauthenticationRequired(providerID: .googlePlay)
        }
        // Live entitlement exchange is a gate research deliverable.
        throw HarborError.feasibilityGateIncomplete(
            reason: "Play entitlement exchange is not implemented until the feasibility gate provides a tested contract"
        )
    }

    public func resolveDelivery(
        accountID: UUID,
        buildID: MinecraftBuildID
    ) async throws -> PackageDelivery {
        try policy.requireLiveProvider()
        guard buildID.abi == .arm64v8a else {
            throw HarborError.invalidPackage(reason: "Only arm64-v8a deliveries are accepted in the MVP")
        }
        _ = try await sessions.requireReady(accountID: accountID, credentials: credentials)
        throw HarborError.feasibilityGateIncomplete(
            reason: "Delivery resolution requires verified Play package metadata and integrity semantics"
        )
    }

    // MARK: Authentication

    public func beginSignIn() async throws -> AuthSessionHandle {
        try policy.requireAuthImplementation()
        throw HarborError.feasibilityGateIncomplete(
            reason: "Sign-in implementation awaits documented browser contract + Play token validity proof"
        )
    }

    public func restoreSession(accountID: UUID) async throws -> AuthSessionHandle {
        let reference = CredentialReference(accountID: accountID, purpose: .storeRefresh, key: "play-session")
        do {
            _ = try await credentials.retrieve(for: reference)
        } catch {
            throw HarborError.reauthenticationRequired(providerID: .googlePlay)
        }
        throw HarborError.reauthenticationRequired(providerID: .googlePlay)
    }

    public func refreshSession(accountID: UUID) async throws -> AuthSessionHandle {
        try policy.requireAuthImplementation()
        throw HarborError.reauthenticationRequired(providerID: .googlePlay)
    }

    public func signOut(accountID: UUID) async throws {
        let ref = CredentialReference(accountID: accountID, purpose: .storeSession, key: "play-session")
        let refresh = CredentialReference(accountID: accountID, purpose: .storeRefresh, key: "play-session")
        try? await credentials.delete(for: ref)
        try? await credentials.delete(for: refresh)
        await sessions.remove(accountID: accountID)
    }

    public func progressStream(accountID: UUID?) -> AsyncStream<AuthenticationProgress> {
        AsyncStream { continuation in
            continuation.yield(
                AuthenticationProgress(
                    phase: .signedOut,
                    message: "Play sign-in is gated on the feasibility contract."
                )
            )
            continuation.finish()
        }
    }
}

// MARK: - Policy

public struct PlayPolicy: Sendable {
    public var allowLiveNetwork: Bool
    public var advertisedCapabilities: Set<StoreCapability>

    public static let foundation = PlayPolicy(
        allowLiveNetwork: false,
        advertisedCapabilities: [.signIn, .restoreSession]
    )

    public static let liveResearch = PlayPolicy(
        allowLiveNetwork: true,
        advertisedCapabilities: [
            .signIn, .restoreSession, .entitlementCheck,
            .currentVersionList, .historicalCatalog, .deliveryResolution,
        ]
    )

    func requireLiveProvider() throws {
        guard allowLiveNetwork else {
            throw HarborError.feasibilityGateIncomplete(
                reason: "Live Play provider traffic is disabled in the foundation build"
            )
        }
    }

    func requireAuthImplementation() throws {
        throw HarborError.feasibilityGateIncomplete(
            reason: "Google Play authentication contract is not established"
        )
    }
}

// MARK: - Sessions (holds account identity only; secrets stay in Keychain)

public actor SessionRegistry {
    public struct Entry: Sendable {
        public var accountID: UUID
        public var state: AccountRecord.SessionState
        public var updatedAt: Date
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    public func requireReady(accountID: UUID, credentials: any CredentialStore) async throws -> Entry? {
        if let entry = entries[accountID], entry.state == .ready {
            return entry
        }
        return nil
    }

    public func remove(accountID: UUID) {
        entries.removeValue(forKey: accountID)
    }

    public func upsert(accountID: UUID, state: AccountRecord.SessionState) {
        entries[accountID] = Entry(accountID: accountID, state: state, updatedAt: Date())
    }
}

// MARK: - Reviewed foundation catalog seed

public enum FoundationCatalog {
    public static let knownVersions: [MinecraftVersion] = [
        MinecraftVersion(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 0,
                abi: .arm64v8a,
                channel: .release
            ),
            originalVersionName: "placeholder-not-deliverable",
            displayName: "Placeholder (not deliverable)",
            providerID: .googlePlay,
            availability: .unchecked,
            provenance: .bedrockHarborCatalog,
            notes: "Catalog seed only. Replace with reviewed builds after the feasibility gate."
        )
    ]
}

// Browser presentation contracts live in HarborDomain so validation can be
// unit-tested without depending on store-adapter composition.
