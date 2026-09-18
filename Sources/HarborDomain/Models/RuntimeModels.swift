import Foundation

/// Approved upstream runtime identity and artifacts.
public struct RuntimeRelease: Hashable, Sendable, Codable, Identifiable {
    public enum Architecture: String, Hashable, Sendable, Codable {
        case arm64
        case x86_64
        case universal
    }

    public var id: String
    public var displayName: String
    public var upstreamReleaseTag: String
    public var assetName: String
    public var artifactSHA256: String
    public var architecture: Architecture
    public var minimumOS: String
    public var clientRevision: String?
    public var manifestRevision: String?
    public var layoutAdapterID: String
    public var capabilities: [RuntimeCapability]
    public var helperRequirements: [String]
    public var requiredPatchIDs: [String]
    public var licenseNotices: [String]
    public var sourceURLs: [String]
    public var qualificationEvidence: String?
    public var downloadURL: URL?

    public init(
        id: String,
        displayName: String,
        upstreamReleaseTag: String,
        assetName: String,
        artifactSHA256: String,
        architecture: Architecture,
        minimumOS: String,
        clientRevision: String? = nil,
        manifestRevision: String? = nil,
        layoutAdapterID: String,
        capabilities: [RuntimeCapability] = [],
        helperRequirements: [String] = [],
        requiredPatchIDs: [String] = [],
        licenseNotices: [String] = [],
        sourceURLs: [String] = [],
        qualificationEvidence: String? = nil,
        downloadURL: URL? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.upstreamReleaseTag = upstreamReleaseTag
        self.assetName = assetName
        self.artifactSHA256 = artifactSHA256
        self.architecture = architecture
        self.minimumOS = minimumOS
        self.clientRevision = clientRevision
        self.manifestRevision = manifestRevision
        self.layoutAdapterID = layoutAdapterID
        self.capabilities = capabilities
        self.helperRequirements = helperRequirements
        self.requiredPatchIDs = requiredPatchIDs
        self.licenseNotices = licenseNotices
        self.sourceURLs = sourceURLs
        self.qualificationEvidence = qualificationEvidence
        self.downloadURL = downloadURL
    }
}

public struct RuntimeCapability: Hashable, Sendable, Codable {
    public var id: String
    public var displayName: String
    public var isRequired: Bool

    public init(id: String, displayName: String, isRequired: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isRequired = isRequired
    }
}

public enum RuntimeHealth: String, Hashable, Sendable, Codable {
    case unknown
    case healthy
    case degraded
    case broken
    case quarantined
}

/// Locally installed runtime deployment.
public struct RuntimeInstallation: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var releaseID: String
    public var relativeInstallPath: String
    public var artifactSHA256: String
    public var installedAt: Date
    public var health: RuntimeHealth
    public var verificationNotes: [String]
    public var helperGeneration: String
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        releaseID: String,
        relativeInstallPath: String,
        artifactSHA256: String,
        installedAt: Date = Date(),
        health: RuntimeHealth = .unknown,
        verificationNotes: [String] = [],
        helperGeneration: String = "bh-helpers-v1",
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.releaseID = releaseID
        self.relativeInstallPath = relativeInstallPath
        self.artifactSHA256 = artifactSHA256
        self.installedAt = installedAt
        self.health = health
        self.verificationNotes = verificationNotes
        self.helperGeneration = helperGeneration
        self.schemaVersion = schemaVersion
    }
}

/// Profile with isolated game data root.
public struct Profile: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var selectedInstallationID: UUID?
    public var pinnedRuntimeReleaseID: String?
    public var dataRootID: String
    public var windowWidth: Int?
    public var windowHeight: Int?
    public var loggingEnabled: Bool
    public var schemaVersion: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        selectedInstallationID: UUID? = nil,
        pinnedRuntimeReleaseID: String? = nil,
        dataRootID: String = UUID().uuidString.lowercased(),
        windowWidth: Int? = nil,
        windowHeight: Int? = nil,
        loggingEnabled: Bool = true,
        schemaVersion: Int = 1,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.selectedInstallationID = selectedInstallationID
        self.pinnedRuntimeReleaseID = pinnedRuntimeReleaseID
        self.dataRootID = dataRootID
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.loggingEnabled = loggingEnabled
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
    }
}

/// Non-secret account record. Secrets live only in Keychain via CredentialStore.
public struct AccountRecord: Hashable, Sendable, Codable, Identifiable {
    public enum SessionState: String, Hashable, Sendable, Codable {
        case signedOut
        case signingIn
        case requiresReauth
        case ready
        case blocked
    }

    public var id: UUID
    public var providerID: ProviderID
    public var accountLabel: String
    public var sessionState: SessionState
    public var keychainReference: String
    public var entitlementCheckedAt: Date?
    public var hasStoreEntitlement: Bool?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        providerID: ProviderID,
        accountLabel: String,
        sessionState: SessionState = .signedOut,
        keychainReference: String,
        entitlementCheckedAt: Date? = nil,
        hasStoreEntitlement: Bool? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.providerID = providerID
        self.accountLabel = accountLabel
        self.sessionState = sessionState
        self.keychainReference = keychainReference
        self.entitlementCheckedAt = entitlementCheckedAt
        self.hasStoreEntitlement = hasStoreEntitlement
        self.schemaVersion = schemaVersion
    }
}

public enum CompatibilityStatus: String, Hashable, Sendable, Codable {
    case unsupported
    case unknown
    case partiallyCompatible
    case compatible
}

public enum EvidenceSource: String, Hashable, Sendable, Codable {
    case locallyMeasured
    case manuallyTested
    case upstreamDocumented
    case issueReported
    case inferred
}

public enum CapabilityGroup: String, Hashable, Sendable, Codable, CaseIterable {
    case coreLaunch
    case graphics
    case audio
    case xboxAuth
    case multiplayer
    case nativeLibraries
    case patches
}

public struct CapabilityResult: Hashable, Sendable, Codable, Identifiable {
    public var group: CapabilityGroup
    public var status: CompatibilityStatus
    public var evidenceSource: EvidenceSource
    public var summary: String

    public var id: String { group.rawValue }

    public init(
        group: CapabilityGroup,
        status: CompatibilityStatus,
        evidenceSource: EvidenceSource,
        summary: String
    ) {
        self.group = group
        self.status = status
        self.evidenceSource = evidenceSource
        self.summary = summary
    }
}

public struct CompatibilityCheck: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var ruleID: String
    public var title: String
    public var detail: String
    public var severity: Severity
    public var blocksLaunch: Bool
    public var remediationID: String?
    public var evidenceSource: EvidenceSource

    public enum Severity: String, Hashable, Sendable, Codable {
        case info
        case warning
        case critical
    }

    public init(
        id: String = UUID().uuidString,
        ruleID: String,
        title: String,
        detail: String,
        severity: Severity,
        blocksLaunch: Bool = false,
        remediationID: String? = nil,
        evidenceSource: EvidenceSource = .inferred
    ) {
        self.id = id
        self.ruleID = ruleID
        self.title = title
        self.detail = detail
        self.severity = severity
        self.blocksLaunch = blocksLaunch
        self.remediationID = remediationID
        self.evidenceSource = evidenceSource
    }
}

public struct CompatibilityReport: Hashable, Sendable, Codable {
    public var overall: CompatibilityStatus
    public var capabilities: [CapabilityResult]
    public var checks: [CompatibilityCheck]
    public var warnings: [String]
    public var rulesetRevision: String
    public var rulesetAgeDays: Int?
    public var evaluatedAt: Date
    public var evidenceNotes: [String]

    public var launchBlocked: Bool {
        checks.contains(where: \.blocksLaunch) || overall == .unsupported
    }

    public init(
        overall: CompatibilityStatus,
        capabilities: [CapabilityResult] = [],
        checks: [CompatibilityCheck] = [],
        warnings: [String] = [],
        rulesetRevision: String,
        rulesetAgeDays: Int? = nil,
        evaluatedAt: Date = Date(),
        evidenceNotes: [String] = []
    ) {
        self.overall = overall
        self.capabilities = capabilities
        self.checks = checks
        self.warnings = warnings
        self.rulesetRevision = rulesetRevision
        self.rulesetAgeDays = rulesetAgeDays
        self.evaluatedAt = evaluatedAt
        self.evidenceNotes = evidenceNotes
    }
}

public struct WorldRecord: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var profileID: UUID
    public var dataRootID: String
    public var directoryID: String
    public var displayName: String
    public var levelNameFromFile: String?
    public var thumbnailRelativePath: String?
    public var sizeBytes: Int64?
    public var modifiedAt: Date?
    public var metadataState: MetadataState

    public enum MetadataState: String, Hashable, Sendable, Codable {
        case complete
        case partial
        case unknown
    }

    public init(
        id: String,
        profileID: UUID,
        dataRootID: String,
        directoryID: String,
        displayName: String,
        levelNameFromFile: String? = nil,
        thumbnailRelativePath: String? = nil,
        sizeBytes: Int64? = nil,
        modifiedAt: Date? = nil,
        metadataState: MetadataState = .unknown
    ) {
        self.id = id
        self.profileID = profileID
        self.dataRootID = dataRootID
        self.directoryID = directoryID
        self.displayName = displayName
        self.levelNameFromFile = levelNameFromFile
        self.thumbnailRelativePath = thumbnailRelativePath
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.metadataState = metadataState
    }
}

public struct BackupManifest: Hashable, Sendable, Codable, Identifiable {
    public struct FileEntry: Hashable, Sendable, Codable {
        public var relativePath: String
        public var byteCount: Int64
        public var sha256: String

        public init(relativePath: String, byteCount: Int64, sha256: String) {
            self.relativePath = relativePath
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public var id: UUID
    public var worldDirectoryID: String
    public var profileID: UUID
    public var dataRootID: String
    public var createdAt: Date
    public var gameVersionName: String?
    public var files: [FileEntry]
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        worldDirectoryID: String,
        profileID: UUID,
        dataRootID: String,
        createdAt: Date = Date(),
        gameVersionName: String? = nil,
        files: [FileEntry] = [],
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.worldDirectoryID = worldDirectoryID
        self.profileID = profileID
        self.dataRootID = dataRootID
        self.createdAt = createdAt
        self.gameVersionName = gameVersionName
        self.files = files
        self.schemaVersion = schemaVersion
    }
}

public enum LaunchSessionState: String, Hashable, Sendable, Codable {
    case preparing
    case starting
    case running
    case exited
    case failed
    case terminationRequested
    case terminated
}

public struct LaunchSession: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var profileID: UUID
    public var installationID: UUID?
    public var runtimeReleaseID: String?
    public var patchIDs: [String]
    public var state: LaunchSessionState
    public var processIdentifier: Int32?
    public var startedAt: Date?
    public var endedAt: Date?
    public var exitCode: Int32?
    public var terminationSignal: Int32?
    public var logRelativePath: String?
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        profileID: UUID,
        installationID: UUID? = nil,
        runtimeReleaseID: String? = nil,
        patchIDs: [String] = [],
        state: LaunchSessionState = .preparing,
        processIdentifier: Int32? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        terminationSignal: Int32? = nil,
        logRelativePath: String? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.profileID = profileID
        self.installationID = installationID
        self.runtimeReleaseID = runtimeReleaseID
        self.patchIDs = patchIDs
        self.state = state
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.logRelativePath = logRelativePath
        self.schemaVersion = schemaVersion
    }
}

/// Typed launch plan. Never executed via shell string interpolation.
public struct LaunchPlan: Hashable, Sendable, Codable {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectoryURL: URL
    public var environment: [String: String]
    public var gameDataDirectoryURL: URL
    public var cacheDirectoryURL: URL
    public var profileID: UUID
    public var installationID: UUID?
    public var runtimeReleaseID: String?

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        environment: [String: String],
        gameDataDirectoryURL: URL,
        cacheDirectoryURL: URL,
        profileID: UUID,
        installationID: UUID? = nil,
        runtimeReleaseID: String? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
        self.gameDataDirectoryURL = gameDataDirectoryURL
        self.cacheDirectoryURL = cacheDirectoryURL
        self.profileID = profileID
        self.installationID = installationID
        self.runtimeReleaseID = runtimeReleaseID
    }
}
