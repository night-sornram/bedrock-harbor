import Foundation

/// Typed launcher errors. Secrets must never be attached.
public enum HarborError: Error, Sendable, Equatable {
    case cancelled
    case reauthenticationRequired(providerID: ProviderID)
    case entitlementDenied(reason: String)
    case unavailableVersion(buildID: MinecraftBuildID)
    case invalidPackage(reason: String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case unsupportedRuntime(reason: String)
    case integrityFailure(reason: String)
    case credentialStoreUnavailable(reason: String)
    case unauthorizedCallback(reason: String)
    case archiveRejected(reason: String)
    case installationInUse(installationID: UUID)
    case gameRunning(profileID: UUID)
    case compatibilityBlocked(reason: String)
    case persistenceFailure(reason: String)
    case networkFailure(reason: String)
    case providerFailure(reason: String)
    case unsupportedOperation(reason: String)
    case feasibilityGateIncomplete(reason: String)
    case internalInconsistency(reason: String)
}

extension HarborError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The operation was cancelled."
        case .reauthenticationRequired(let providerID):
            return "Sign in again for \(providerID.rawValue)."
        case .entitlementDenied(let reason):
            return "Store entitlement was denied: \(reason)"
        case .unavailableVersion(let buildID):
            return "This account/device cannot download \(buildID)."
        case .invalidPackage(let reason):
            return "Package validation failed: \(reason)"
        case .insufficientDiskSpace(let required, let available):
            return "Not enough disk space. Required \(required) bytes, available \(available)."
        case .unsupportedRuntime(let reason):
            return "Runtime is not supported: \(reason)"
        case .integrityFailure(let reason):
            return "Integrity check failed: \(reason)"
        case .credentialStoreUnavailable(let reason):
            return "Credential storage is unavailable: \(reason)"
        case .unauthorizedCallback(let reason):
            return "Authentication callback rejected: \(reason)"
        case .archiveRejected(let reason):
            return "Archive rejected: \(reason)"
        case .installationInUse:
            return "That installation is currently in use."
        case .gameRunning:
            return "A game session is already running for this profile."
        case .compatibilityBlocked(let reason):
            return "Launch blocked by compatibility rules: \(reason)"
        case .persistenceFailure(let reason):
            return "Metadata storage failed: \(reason)"
        case .networkFailure(let reason):
            return "Network operation failed: \(reason)"
        case .providerFailure(let reason):
            return "Provider operation failed: \(reason)"
        case .unsupportedOperation(let reason):
            return "Unsupported operation: \(reason)"
        case .feasibilityGateIncomplete(let reason):
            return "Feasibility gate incomplete: \(reason)"
        case .internalInconsistency(let reason):
            return "Internal inconsistency: \(reason)"
        }
    }
}

public enum CredentialPurpose: String, Hashable, Sendable, Codable {
    case storeSession
    case storeRefresh
    case helperHandoff
}

public struct CredentialReference: Hashable, Sendable, Codable {
    public var accountID: UUID
    public var purpose: CredentialPurpose
    public var key: String

    public init(accountID: UUID, purpose: CredentialPurpose, key: String) {
        self.accountID = accountID
        self.purpose = purpose
        self.key = key
    }

    public var opaqueDescription: String {
        "\(accountID.uuidString.prefix(8)).\(purpose.rawValue).\(key)"
    }
}

public enum StoreCapability: String, Hashable, Sendable, Codable, CaseIterable {
    case signIn
    case restoreSession
    case entitlementCheck
    case currentVersionList
    case historicalCatalog
    case deliveryResolution
}

public struct ProviderCapabilities: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var supported: Set<StoreCapability>
    public var notes: [String]

    public init(providerID: ProviderID, supported: Set<StoreCapability>, notes: [String] = []) {
        self.providerID = providerID
        self.supported = supported
        self.notes = notes
    }
}

public struct EntitlementResult: Hashable, Sendable, Codable {
    public var isEntitled: Bool
    public var checkedAt: Date
    public var reason: String?

    public init(isEntitled: Bool, checkedAt: Date = Date(), reason: String? = nil) {
        self.isEntitled = isEntitled
        self.checkedAt = checkedAt
        self.reason = reason
    }
}

public enum AuthenticationPhase: String, Hashable, Sendable, Codable {
    case signedOut
    case browserInteraction
    case credentialExchange
    case deviceBootstrap
    case entitlementCheck
    case ready
    case failed
}

public struct AuthenticationProgress: Hashable, Sendable, Codable {
    public var phase: AuthenticationPhase
    public var message: String
    public var accountID: UUID?

    public init(phase: AuthenticationPhase, message: String, accountID: UUID? = nil) {
        self.phase = phase
        self.message = message
        self.accountID = accountID
    }
}

public struct AuthSessionHandle: Hashable, Sendable, Codable {
    public var accountID: UUID
    public var providerID: ProviderID
    public var credentialReference: CredentialReference
    public var expiresAt: Date?

    public init(accountID: UUID, providerID: ProviderID, credentialReference: CredentialReference, expiresAt: Date? = nil) {
        self.accountID = accountID
        self.providerID = providerID
        self.credentialReference = credentialReference
        self.expiresAt = expiresAt
    }
}

public enum DownloadProgress: Hashable, Sendable, Codable {
    case indeterminate
    case bytes(received: Int64, expected: Int64?)
    case completed(URL)
    case failed(String)

    public var fractionCompleted: Double? {
        switch self {
        case .indeterminate, .completed, .failed:
            return nil
        case .bytes(let received, let expected):
            guard let expected, expected > 0 else { return nil }
            return Double(received) / Double(expected)
        }
    }
}

public struct DownloadRequest: Hashable, Sendable, Codable {
    public var id: UUID
    public var purpose: String
    public var authorizationHandle: String?
    public var expectedSHA256: String?
    public var expectedByteCount: Int64?

    public init(
        id: UUID = UUID(),
        purpose: String,
        authorizationHandle: String? = nil,
        expectedSHA256: String? = nil,
        expectedByteCount: Int64? = nil
    ) {
        self.id = id
        self.purpose = purpose
        self.authorizationHandle = authorizationHandle
        self.expectedSHA256 = expectedSHA256
        self.expectedByteCount = expectedByteCount
    }
}

public struct DoctorFinding: Hashable, Sendable, Codable, Identifiable {
    public enum Severity: String, Hashable, Sendable, Codable {
        case ok
        case warning
        case critical
        case unknown
    }

    public var id: String
    public var title: String
    public var detail: String
    public var severity: Severity

    public init(id: String, title: String, detail: String, severity: Severity) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
    }
}

public struct DiagnosticsSnapshot: Hashable, Sendable, Codable {
    public var generatedAt: Date
    public var findings: [DoctorFinding]
    public var rulesetRevision: String?
    public var lastLaunchSessionID: UUID?
    public var redactedSummary: String

    public init(
        generatedAt: Date = Date(),
        findings: [DoctorFinding] = [],
        rulesetRevision: String? = nil,
        lastLaunchSessionID: UUID? = nil,
        redactedSummary: String = ""
    ) {
        self.generatedAt = generatedAt
        self.findings = findings
        self.rulesetRevision = rulesetRevision
        self.lastLaunchSessionID = lastLaunchSessionID
        self.redactedSummary = redactedSummary
    }
}

public enum ContentKind: String, Hashable, Sendable, Codable {
    case world
    case resourcePack
    case behaviorPack
    case mixedAddon
    case template
    case unsupported
}

public struct ContentInspection: Hashable, Sendable, Codable {
    public var sourceFileName: String
    public var kind: ContentKind
    public var declaredName: String?
    public var declaredUUID: String?
    public var warnings: [String]
    public var isSupported: Bool

    public init(
        sourceFileName: String,
        kind: ContentKind,
        declaredName: String? = nil,
        declaredUUID: String? = nil,
        warnings: [String] = [],
        isSupported: Bool
    ) {
        self.sourceFileName = sourceFileName
        self.kind = kind
        self.declaredName = declaredName
        self.declaredUUID = declaredUUID
        self.warnings = warnings
        self.isSupported = isSupported
    }
}

public struct ImportPlan: Hashable, Sendable, Codable {
    public var profileID: UUID
    public var dataRootID: String
    public var inspections: [ContentInspection]
    public var destinationDescription: String
    public var blockedReasons: [String]

    public init(
        profileID: UUID,
        dataRootID: String,
        inspections: [ContentInspection],
        destinationDescription: String,
        blockedReasons: [String] = []
    ) {
        self.profileID = profileID
        self.dataRootID = dataRootID
        self.inspections = inspections
        self.destinationDescription = destinationDescription
        self.blockedReasons = blockedReasons
    }

    public var canCommit: Bool { blockedReasons.isEmpty && !inspections.isEmpty }
}
