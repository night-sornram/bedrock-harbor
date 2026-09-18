import Foundation

/// Stable identity for a Minecraft package variant.
/// Android version codes stay associated with package variant + ABI; they are not free-floating.
public struct MinecraftBuildID: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum ABI: String, Hashable, Sendable, Codable, CaseIterable {
        case arm64v8a = "arm64-v8a"
        case armeabiV7a = "armeabi-v7a"
        case x86 = "x86"
        case x86_64 = "x86_64"
    }

    public enum DistributionChannel: String, Hashable, Sendable, Codable, CaseIterable {
        case release
        case beta
        case unknown
    }

    public var packageIdentifier: String
    public var versionCode: Int64
    public var abi: ABI
    public var channel: DistributionChannel

    public init(
        packageIdentifier: String,
        versionCode: Int64,
        abi: ABI,
        channel: DistributionChannel = .release
    ) {
        self.packageIdentifier = packageIdentifier
        self.versionCode = versionCode
        self.abi = abi
        self.channel = channel
    }

    public var description: String {
        "\(packageIdentifier)@\(versionCode)/\(abi.rawValue)/\(channel.rawValue)"
    }
}

/// Catalog state for a Minecraft build.
public enum MinecraftAvailability: String, Hashable, Sendable, Codable {
    /// Version identifier is recorded in BedrockHarbor's catalog.
    case known
    /// Provider currently offers delivery for this account/device.
    case available
    /// Not deliverable to this account/device (withhold, region, withdrawn, etc.).
    case unavailable
    /// Not checked against the provider in this session.
    case unchecked
}

public enum VersionProvenance: String, Hashable, Sendable, Codable {
    case bedrockHarborCatalog
    case priorInstallation
    case providerCatalog
    case manual
}

/// A Minecraft version as managed by BedrockHarbor.
/// Display names are not filesystem identifiers; original version strings are retained verbatim.
public struct MinecraftVersion: Hashable, Sendable, Codable, Identifiable {
    public var buildID: MinecraftBuildID
    /// Original provider/version string (e.g. "1.21.2.02"). Not parsed as SemVer.
    public var originalVersionName: String
    public var displayName: String
    public var providerID: ProviderID
    public var availability: MinecraftAvailability
    public var provenance: VersionProvenance
    public var notes: String?

    public var id: String { buildID.description }

    public init(
        buildID: MinecraftBuildID,
        originalVersionName: String,
        displayName: String? = nil,
        providerID: ProviderID,
        availability: MinecraftAvailability = .unchecked,
        provenance: VersionProvenance = .bedrockHarborCatalog,
        notes: String? = nil
    ) {
        self.buildID = buildID
        self.originalVersionName = originalVersionName
        self.displayName = displayName ?? originalVersionName
        self.providerID = providerID
        self.availability = availability
        self.provenance = provenance
        self.notes = notes
    }
}

public struct ProviderID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let googlePlay: ProviderID = "google-play"
}

/// Authorized package delivery for a build. Sensitive authorization material stays transient.
public struct PackageDelivery: Hashable, Sendable, Codable {
    public struct Artifact: Hashable, Sendable, Codable, Identifiable {
        public enum Role: String, Hashable, Sendable, Codable {
            case base
            case split
            case asset
        }

        public enum Verification: Hashable, Sendable, Codable {
            case none
            case sha256(String)
            /// Provider-supplied digest whose meaning has been established by research.
            case providerDigest(algorithm: String, value: String)
        }

        public var id: String
        public var role: Role
        public var suggestedFileName: String
        public var expectedByteCount: Int64?
        public var verification: Verification
        /// Non-secret relative hint for packaging/layout adapters.
        public var layoutHint: String?

        public init(
            id: String,
            role: Role,
            suggestedFileName: String,
            expectedByteCount: Int64? = nil,
            verification: Verification = .none,
            layoutHint: String? = nil
        ) {
            self.id = id
            self.role = role
            self.suggestedFileName = suggestedFileName
            self.expectedByteCount = expectedByteCount
            self.verification = verification
            self.layoutHint = layoutHint
        }
    }

    public var buildID: MinecraftBuildID
    public var artifacts: [Artifact]
    public var resolvedAt: Date
    public var expiresAt: Date?
    /// Opaque handle to transient authorization material held by the provider, not the URL itself.
    public var authorizationHandle: String?

    public init(
        buildID: MinecraftBuildID,
        artifacts: [Artifact],
        resolvedAt: Date = Date(),
        expiresAt: Date? = nil,
        authorizationHandle: String? = nil
    ) {
        self.buildID = buildID
        self.artifacts = artifacts
        self.resolvedAt = resolvedAt
        self.expiresAt = expiresAt
        self.authorizationHandle = authorizationHandle
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

public enum InstallationIntegrity: String, Hashable, Sendable, Codable {
    case pendingVerification
    case verified
    case failed
    case unknown
}

/// Immutable, committed local game installation.
public struct InstalledMinecraft: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var buildID: MinecraftBuildID
    public var originalVersionName: String
    /// Relative path under Application Support Installations/.
    public var relativeGameDirectory: String
    public var integrity: InstallationIntegrity
    public var installedAt: Date
    public var providerID: ProviderID
    public var packageReceipts: [String]
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        buildID: MinecraftBuildID,
        originalVersionName: String,
        relativeGameDirectory: String,
        integrity: InstallationIntegrity = .pendingVerification,
        installedAt: Date = Date(),
        providerID: ProviderID,
        packageReceipts: [String] = [],
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.buildID = buildID
        self.originalVersionName = originalVersionName
        self.relativeGameDirectory = relativeGameDirectory
        self.integrity = integrity
        self.installedAt = installedAt
        self.providerID = providerID
        self.packageReceipts = packageReceipts
        self.schemaVersion = schemaVersion
    }
}
