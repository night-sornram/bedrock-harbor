import Foundation
import HarborDomain

// MARK: - Rule schema

public struct CompatibilityRule: Hashable, Sendable, Codable, Identifiable {
    public struct Predicates: Hashable, Sendable, Codable {
        public var osVersionMin: String?
        public var osVersionMax: String?
        public var architectures: [String]?
        public var blockIfTranslated: Bool?
        public var gamePackageIdentifiers: [String]?
        public var gameVersionCodes: [Int64]?
        public var gameABIs: [String]?
        public var runtimeReleaseIDs: [String]?
        public var runtimeSHA256: [String]?
        public var requiredPatchIDs: [String]?
        public var forbiddenPatchIDs: [String]?
        public var requiresInstallationVerified: Bool?

        public init(
            osVersionMin: String? = nil,
            osVersionMax: String? = nil,
            architectures: [String]? = nil,
            blockIfTranslated: Bool? = nil,
            gamePackageIdentifiers: [String]? = nil,
            gameVersionCodes: [Int64]? = nil,
            gameABIs: [String]? = nil,
            runtimeReleaseIDs: [String]? = nil,
            runtimeSHA256: [String]? = nil,
            requiredPatchIDs: [String]? = nil,
            forbiddenPatchIDs: [String]? = nil,
            requiresInstallationVerified: Bool? = nil
        ) {
            self.osVersionMin = osVersionMin
            self.osVersionMax = osVersionMax
            self.architectures = architectures
            self.blockIfTranslated = blockIfTranslated
            self.gamePackageIdentifiers = gamePackageIdentifiers
            self.gameVersionCodes = gameVersionCodes
            self.gameABIs = gameABIs
            self.runtimeReleaseIDs = runtimeReleaseIDs
            self.runtimeSHA256 = runtimeSHA256
            self.requiredPatchIDs = requiredPatchIDs
            self.forbiddenPatchIDs = forbiddenPatchIDs
            self.requiresInstallationVerified = requiresInstallationVerified
        }
    }

    public var id: String
    public var capability: CapabilityGroup
    public var predicates: Predicates
    public var severity: CompatibilityCheck.Severity
    public var blocksLaunch: Bool
    public var resultStatus: CompatibilityStatus
    public var explanation: String
    public var remediationID: String?
    public var evidenceSource: EvidenceSource
    public var verifiedOn: String?

    public init(
        id: String,
        capability: CapabilityGroup,
        predicates: Predicates = Predicates(),
        severity: CompatibilityCheck.Severity = .info,
        blocksLaunch: Bool = false,
        resultStatus: CompatibilityStatus,
        explanation: String,
        remediationID: String? = nil,
        evidenceSource: EvidenceSource = .inferred,
        verifiedOn: String? = nil
    ) {
        self.id = id
        self.capability = capability
        self.predicates = predicates
        self.severity = severity
        self.blocksLaunch = blocksLaunch
        self.resultStatus = resultStatus
        self.explanation = explanation
        self.remediationID = remediationID
        self.evidenceSource = evidenceSource
        self.verifiedOn = verifiedOn
    }
}

public struct CompatibilityRuleset: Hashable, Sendable, Codable {
    public var revision: String
    public var schemaVersion: Int
    public var publishedAt: Date?
    public var rules: [CompatibilityRule]
    public var signature: String?

    public init(
        revision: String,
        schemaVersion: Int = 1,
        publishedAt: Date? = nil,
        rules: [CompatibilityRule],
        signature: String? = nil
    ) {
        self.revision = revision
        self.schemaVersion = schemaVersion
        self.publishedAt = publishedAt
        self.rules = rules
        self.signature = signature
    }

    public var ageDays: Int? {
        guard let publishedAt else { return nil }
        return Calendar.current.dateComponents([.day], from: publishedAt, to: Date()).day
    }
}

// MARK: - Bundled baseline rules

public enum BundledRuleset {
    public static let current = CompatibilityRuleset(
        revision: "bh-rules-2026.09.foundation",
        schemaVersion: 1,
        publishedAt: Date(timeIntervalSince1970: 1_789_689_600),
        rules: [
            CompatibilityRule(
                id: "arch.requires.arm64",
                capability: .coreLaunch,
                predicates: .init(architectures: ["arm64"]),
                severity: .critical,
                blocksLaunch: true,
                resultStatus: .unsupported,
                explanation: "BedrockHarbor targets native Apple Silicon (arm64). Intel/Rosetta is out of MVP scope.",
                evidenceSource: .upstreamDocumented,
                verifiedOn: "2026-09-18"
            ),
            CompatibilityRule(
                id: "arch.reject.translated",
                capability: .coreLaunch,
                predicates: .init(blockIfTranslated: true),
                severity: .critical,
                blocksLaunch: true,
                resultStatus: .unsupported,
                explanation: "Translated processes are not a supported launch configuration.",
                evidenceSource: .upstreamDocumented,
                verifiedOn: "2026-09-18"
            ),
            CompatibilityRule(
                id: "abi.requires.arm64-v8a",
                capability: .coreLaunch,
                predicates: .init(gameABIs: ["arm64-v8a"]),
                severity: .critical,
                blocksLaunch: true,
                resultStatus: .unsupported,
                explanation: "Game packages must be arm64-v8a. Other ABIs are unsupported in the MVP.",
                evidenceSource: .upstreamDocumented,
                verifiedOn: "2026-09-18"
            ),
            CompatibilityRule(
                id: "integrity.verified.required",
                capability: .coreLaunch,
                predicates: .init(requiresInstallationVerified: true),
                severity: .critical,
                blocksLaunch: true,
                resultStatus: .unsupported,
                explanation: "Launch requires a verified installation receipt. Unverified packages are blocked.",
                evidenceSource: .locallyMeasured,
                verifiedOn: "2026-09-18"
            ),
            CompatibilityRule(
                id: "runtime.unknown-until-qualified",
                capability: .coreLaunch,
                severity: .warning,
                blocksLaunch: false,
                resultStatus: .unknown,
                explanation: "No runtime identity was provided. Core launch cannot be affirmed until an approved runtime is selected and qualified.",
                remediationID: "runtime.selectApproved",
                evidenceSource: .inferred,
                verifiedOn: "2026-09-18"
            ),
            CompatibilityRule(
                id: "patch.blocked-unprovenanced",
                capability: .patches,
                predicates: .init(forbiddenPatchIDs: ["mcpelauncher-updates-unaudited"]),
                severity: .critical,
                blocksLaunch: true,
                resultStatus: .unsupported,
                explanation: "This patch is blocked until credential-storage behavior and binary provenance are resolved.",
                remediationID: "patch.removeBlocked",
                evidenceSource: .issueReported,
                verifiedOn: "2026-09-18"
            ),
            CompatibilityRule(
                id: "multiplayer.xbox.not-claimed",
                capability: .xboxAuth,
                severity: .warning,
                blocksLaunch: false,
                resultStatus: .unknown,
                explanation: "Xbox/Microsoft game identity is separate from Google Play store auth and is not claimed by the MVP.",
                evidenceSource: .upstreamDocumented,
                verifiedOn: "2026-09-18"
            ),
            CompatibilityRule(
                id: "multiplayer.realms.not-claimed",
                capability: .multiplayer,
                severity: .warning,
                blocksLaunch: false,
                resultStatus: .unknown,
                explanation: "Realms/LAN/friends/PlayFab are not claimed until separately qualified.",
                evidenceSource: .upstreamDocumented,
                verifiedOn: "2026-09-18"
            ),
        ]
    )
}

// MARK: - Evaluator

/// Pure evaluator. No network, no filesystem, no scripts.
public struct RulesetEvaluator: CompatibilityEvaluating, Sendable {
    public let ruleset: CompatibilityRuleset

    public init(ruleset: CompatibilityRuleset = BundledRuleset.current) {
        self.ruleset = ruleset
    }

    public func evaluate(environment: CompatibilityEnvironment) async throws -> CompatibilityReport {
        evaluateSync(environment: environment)
    }

    public func evaluateSync(environment: CompatibilityEnvironment) -> CompatibilityReport {
        guard ruleset.schemaVersion <= 1 else {
            return CompatibilityReport(
                overall: .unknown,
                capabilities: CapabilityGroup.allCases.map {
                    CapabilityResult(
                        group: $0,
                        status: .unknown,
                        evidenceSource: .inferred,
                        summary: "Ruleset schema \(ruleset.schemaVersion) is newer than this evaluator."
                    )
                },
                checks: [
                    CompatibilityCheck(
                        ruleID: "ruleset.schema.unsupported",
                        title: "Unsupported ruleset schema",
                        detail: "Installed ruleset schema \(ruleset.schemaVersion) is not supported by this build.",
                        severity: .warning,
                        blocksLaunch: false,
                        evidenceSource: .locallyMeasured
                    )
                ],
                warnings: ["Using last valid bundled interpretation as unknown."],
                rulesetRevision: ruleset.revision,
                rulesetAgeDays: ruleset.ageDays,
                evidenceNotes: ["Evaluator schema support: 1"]
            )
        }

        var matched: [CompatibilityRule] = []
        var checks: [CompatibilityCheck] = []
        var warnings: [String] = []

        for rule in ruleset.rules {
            if RuleMatcher.matches(rule.predicates, environment: environment) {
                matched.append(rule)
                checks.append(
                    CompatibilityCheck(
                        ruleID: rule.id,
                        title: rule.capability.rawValue,
                        detail: rule.explanation,
                        severity: rule.severity,
                        blocksLaunch: rule.blocksLaunch && rule.resultStatus == .unsupported,
                        remediationID: rule.remediationID,
                        evidenceSource: rule.evidenceSource
                    )
                )
            }
        }

        // When predicates are empty the rule is informational and always applies.
        // runtime.unknown-until-qualified already has empty predicates.

        var byCapability: [CapabilityGroup: CompatibilityStatus] = [:]
        for group in CapabilityGroup.allCases {
            byCapability[group] = .unknown
        }

        // Predicated rules that matched contribute their status.
        for rule in matched where !isEmpty(rule.predicates) || rule.id.hasPrefix("runtime.") {
            let current = byCapability[rule.capability] ?? .unknown
            byCapability[rule.capability] = Self.combine(current, rule.resultStatus)
        }

        // Establish core defaults from environment facts.
        if let game = environment.gameBuildID {
            if game.abi == .arm64v8a, !environment.isTranslated, environment.processArchitecture == "arm64" {
                if environment.runtimeReleaseID != nil, environment.installationIntegrity == .verified {
                    byCapability[.coreLaunch] = Self.combine(byCapability[.coreLaunch] ?? .unknown, .partiallyCompatible)
                } else if environment.runtimeReleaseID == nil {
                    warnings.append("Runtime identity missing; core launch remains unknown.")
                } else if environment.installationIntegrity != .verified {
                    warnings.append("Installation integrity is not verified; core launch is blocked or unknown.")
                }
            }
        } else {
            warnings.append("No game build selected.")
        }

        // Secondary capabilities without positive evidence stay unknown — never green.
        if byCapability[.xboxAuth] == .unknown || byCapability[.xboxAuth] == .partiallyCompatible {
            // leave as unknown/partial; do not invent compatible
        }

        var overall: CompatibilityStatus = .unknown
        if checks.contains(where: { $0.blocksLaunch }) {
            overall = .unsupported
        } else {
            overall = Self.aggregateOverall(byCapability)
        }

        if let age = ruleset.ageDays, age > 180 {
            warnings.append("Compatibility ruleset is \(age) days old.")
        }

        if overall == .compatible {
            // Foundation evaluator never claims full compatibility without explicit evidence rules.
            if !matched.contains(where: { $0.evidenceSource == .manuallyTested && $0.resultStatus == .compatible }) {
                overall = .partiallyCompatible
                warnings.append("No manually tested compatible evidence matched; capped at partiallyCompatible.")
            }
        }

        let capabilities = CapabilityGroup.allCases.map { group in
            CapabilityResult(
                group: group,
                status: byCapability[group] ?? .unknown,
                evidenceSource: evidenceSourceFor(group: group, matched: matched),
                summary: summaryFor(group: group, status: byCapability[group] ?? .unknown)
            )
        }

        return CompatibilityReport(
            overall: overall,
            capabilities: capabilities,
            checks: checks,
            warnings: warnings,
            rulesetRevision: ruleset.revision,
            rulesetAgeDays: ruleset.ageDays,
            evidenceNotes: [
                "ruleset=\(ruleset.revision)",
                "matched=\(matched.map(\.id).sorted().joined(separator: ","))",
            ]
        )
    }

    private func isEmpty(_ predicates: CompatibilityRule.Predicates) -> Bool {
        predicates.osVersionMin == nil
            && predicates.osVersionMax == nil
            && predicates.architectures == nil
            && predicates.blockIfTranslated == nil
            && predicates.gamePackageIdentifiers == nil
            && predicates.gameVersionCodes == nil
            && predicates.gameABIs == nil
            && predicates.runtimeReleaseIDs == nil
            && predicates.runtimeSHA256 == nil
            && predicates.requiredPatchIDs == nil
            && predicates.forbiddenPatchIDs == nil
            && predicates.requiresInstallationVerified == nil
    }

    private func evidenceSourceFor(group: CapabilityGroup, matched: [CompatibilityRule]) -> EvidenceSource {
        let sources = matched.filter { $0.capability == group }.map(\.evidenceSource)
        if sources.contains(.manuallyTested) { return .manuallyTested }
        if sources.contains(.locallyMeasured) { return .locallyMeasured }
        if sources.contains(.upstreamDocumented) { return .upstreamDocumented }
        if sources.contains(.issueReported) { return .issueReported }
        return .inferred
    }

    private func summaryFor(group: CapabilityGroup, status: CompatibilityStatus) -> String {
        switch (group, status) {
        case (.coreLaunch, .unsupported):
            return "Core launch blocked."
        case (.coreLaunch, .partiallyCompatible):
            return "Core launch appears possible with known limitations; not fully qualified."
        case (.coreLaunch, .unknown):
            return "Insufficient evidence for core launch."
        case (.coreLaunch, .compatible):
            return "Core launch supported by evidence."
        case (_, .unknown):
            return "No established evidence for \(group.rawValue)."
        case (_, .unsupported):
            return "\(group.rawValue) is unsupported for this combination."
        case (_, .partiallyCompatible):
            return "\(group.rawValue) has known limitations."
        case (_, .compatible):
            return "\(group.rawValue) supported by evidence."
        }
    }

    /// Worst-of aggregation with unknown treated as non-fatal but non-positive.
    static func combine(_ a: CompatibilityStatus, _ b: CompatibilityStatus) -> CompatibilityStatus {
        let rank: [CompatibilityStatus: Int] = [
            .unsupported: 0,
            .unknown: 1,
            .partiallyCompatible: 2,
            .compatible: 3,
        ]
        return (rank[a] ?? 1) <= (rank[b] ?? 1) ? a : b
    }

    static func aggregateOverall(_ capabilities: [CapabilityGroup: CompatibilityStatus]) -> CompatibilityStatus {
        let core = capabilities[.coreLaunch] ?? .unknown
        if core == .unsupported { return .unsupported }

        let statuses = capabilities.values
        if statuses.contains(.unsupported) {
            // Secondary unsupported without core block → partial, not fully compatible.
            return core == .compatible ? .partiallyCompatible : core
        }
        if core == .unknown { return .unknown }
        if statuses.contains(.unknown) { return .partiallyCompatible }
        if statuses.contains(.partiallyCompatible) { return .partiallyCompatible }
        return .compatible
    }
}

enum RuleMatcher {
    /// Predicate semantics:
    /// - Requirement lists (`architectures`, `gameABIs`, `requiredPatchIDs`,
    ///   `requiresInstallationVerified`) apply when the environment FAILS the requirement.
    /// - Deny lists (`forbiddenPatchIDs`, `blockIfTranslated`) apply when the bad condition holds.
    /// - Targeting lists (`gamePackageIdentifiers`, `gameVersionCodes`, `runtimeReleaseIDs`,
    ///   `runtimeSHA256`) apply only when the environment matches the listed identity.
    static func matches(_ predicates: CompatibilityRule.Predicates, environment: CompatibilityEnvironment) -> Bool {
        var sawPredicate = false
        var shouldApply = false

        if let min = predicates.osVersionMin {
            sawPredicate = true
            if compareVersions(environment.osVersion, min) < 0 { shouldApply = true }
        }
        if let max = predicates.osVersionMax {
            sawPredicate = true
            if compareVersions(environment.osVersion, max) > 0 { shouldApply = true }
        }
        if let archs = predicates.architectures {
            sawPredicate = true
            if !archs.contains(environment.processArchitecture) { shouldApply = true }
        }
        if let blockTranslated = predicates.blockIfTranslated {
            sawPredicate = true
            if blockTranslated, environment.isTranslated { shouldApply = true }
            if !blockTranslated, !environment.isTranslated { shouldApply = true }
        }
        if let packages = predicates.gamePackageIdentifiers {
            sawPredicate = true
            guard let game = environment.gameBuildID, packages.contains(game.packageIdentifier) else {
                return false
            }
            shouldApply = true
        }
        if let codes = predicates.gameVersionCodes {
            sawPredicate = true
            guard let game = environment.gameBuildID, codes.contains(game.versionCode) else {
                return false
            }
            shouldApply = true
        }
        if let abis = predicates.gameABIs {
            sawPredicate = true
            if let game = environment.gameBuildID, !abis.contains(game.abi.rawValue) {
                shouldApply = true
            } else if environment.gameBuildID == nil {
                shouldApply = true
            }
        }
        if let runtimes = predicates.runtimeReleaseIDs {
            sawPredicate = true
            guard let id = environment.runtimeReleaseID, runtimes.contains(id) else {
                return false
            }
            shouldApply = true
        }
        if let hashes = predicates.runtimeSHA256 {
            sawPredicate = true
            guard let sha = environment.runtimeSHA256,
                  hashes.contains(where: { $0.caseInsensitiveCompare(sha) == .orderedSame })
            else {
                return false
            }
            shouldApply = true
        }
        if let required = predicates.requiredPatchIDs {
            sawPredicate = true
            let present = Set(environment.patchIDs)
            if !required.allSatisfy({ present.contains($0) }) { shouldApply = true }
        }
        if let forbidden = predicates.forbiddenPatchIDs {
            sawPredicate = true
            let present = Set(environment.patchIDs)
            if forbidden.contains(where: { present.contains($0) }) { shouldApply = true }
        }
        if let needsVerified = predicates.requiresInstallationVerified {
            sawPredicate = true
            if needsVerified, environment.installationIntegrity != .verified { shouldApply = true }
        }

        // Empty predicates are informational and always apply.
        if !sawPredicate { return true }
        return shouldApply
    }

    /// Numeric-aware dotted compare; non-numeric components compare as strings after numeric parts.
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let l = lhs.split(separator: ".").map(String.init)
        let r = rhs.split(separator: ".").map(String.init)
        let count = max(l.count, r.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : "0"
            let b = i < r.count ? r[i] : "0"
            if let ai = Int(a), let bi = Int(b) {
                if ai != bi { return ai < bi ? -1 : 1 }
            } else {
                let cmp = a.compare(b, options: .numeric)
                if cmp != .orderedSame { return cmp == .orderedAscending ? -1 : 1 }
            }
        }
        return 0
    }
}
