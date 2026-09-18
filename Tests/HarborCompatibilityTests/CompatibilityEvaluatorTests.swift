import Testing
import Foundation
import HarborDomain
@testable import HarborCompatibility

@Suite("Compatibility evaluator")
struct CompatibilityEvaluatorTests {
    private let evaluator = RulesetEvaluator()

    @Test func blocksNonARM64Architecture() {
        let env = CompatibilityEnvironment(
            osVersion: "15.0",
            processArchitecture: "x86_64",
            isTranslated: false,
            gameBuildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 100,
                abi: .arm64v8a
            ),
            installationIntegrity: .verified
        )
        let report = evaluator.evaluateSync(environment: env)
        #expect(report.overall == .unsupported)
        #expect(report.launchBlocked)
        #expect(report.checks.contains { $0.ruleID == "arch.requires.arm64" && $0.blocksLaunch })
    }

    @Test func blocksTranslatedProcess() {
        let env = CompatibilityEnvironment(
            osVersion: "15.0",
            processArchitecture: "arm64",
            isTranslated: true,
            gameBuildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 100,
                abi: .arm64v8a
            ),
            installationIntegrity: .verified
        )
        let report = evaluator.evaluateSync(environment: env)
        #expect(report.overall == .unsupported)
        #expect(report.checks.contains { $0.ruleID == "arch.reject.translated" })
    }

    @Test func blocksWrongABI() {
        let env = CompatibilityEnvironment(
            osVersion: "15.0",
            processArchitecture: "arm64",
            gameBuildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 100,
                abi: .armeabiV7a
            ),
            installationIntegrity: .verified
        )
        let report = evaluator.evaluateSync(environment: env)
        #expect(report.overall == .unsupported)
        #expect(report.checks.contains { $0.ruleID == "abi.requires.arm64-v8a" })
    }

    @Test func blocksUnverifiedInstallation() {
        let env = CompatibilityEnvironment(
            osVersion: "15.0",
            processArchitecture: "arm64",
            gameBuildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 100,
                abi: .arm64v8a
            ),
            runtimeReleaseID: "runtime-1",
            runtimeSHA256: "abc",
            installationIntegrity: .pendingVerification
        )
        let report = evaluator.evaluateSync(environment: env)
        #expect(report.overall == .unsupported)
        #expect(report.checks.contains { $0.ruleID == "integrity.verified.required" })
    }

    @Test func blocksForbiddenPatch() {
        let env = CompatibilityEnvironment(
            osVersion: "15.0",
            processArchitecture: "arm64",
            gameBuildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 100,
                abi: .arm64v8a
            ),
            runtimeReleaseID: "runtime-1",
            runtimeSHA256: "abc",
            patchIDs: ["mcpelauncher-updates-unaudited"],
            installationIntegrity: .verified
        )
        let report = evaluator.evaluateSync(environment: env)
        #expect(report.overall == .unsupported)
        #expect(report.checks.contains { $0.ruleID == "patch.blocked-unprovenanced" })
    }

    @Test func missingRuntimeIsUnknownNotGreen() {
        let env = CompatibilityEnvironment(
            osVersion: "15.0",
            processArchitecture: "arm64",
            gameBuildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 100,
                abi: .arm64v8a
            ),
            installationIntegrity: .verified
        )
        let report = evaluator.evaluateSync(environment: env)
        #expect(report.overall != .compatible)
        #expect(report.overall == .unknown || report.overall == .partiallyCompatible)
        #expect(report.warnings.contains { $0.lowercased().contains("runtime") })
        let core = report.capabilities.first { $0.group == .coreLaunch }
        #expect(core?.status != .compatible)
    }

    @Test func multiplayerStaysUnclaimed() {
        let env = CompatibilityEnvironment(
            osVersion: "15.0",
            processArchitecture: "arm64",
            gameBuildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 100,
                abi: .arm64v8a
            ),
            runtimeReleaseID: "runtime-1",
            runtimeSHA256: "deadbeef",
            installationIntegrity: .verified
        )
        let report = evaluator.evaluateSync(environment: env)
        let multiplayer = report.capabilities.first { $0.group == .multiplayer }
        let xbox = report.capabilities.first { $0.group == .xboxAuth }
        #expect(multiplayer?.status == .unknown || multiplayer?.status == .partiallyCompatible)
        #expect(xbox?.status == .unknown || xbox?.status == .partiallyCompatible)
        #expect(multiplayer?.status != .compatible)
        #expect(xbox?.status != .compatible)
    }

    @Test func versionCompareIsNumericAware() {
        #expect(RuleMatcher.compareVersions("15.0", "14.0") > 0)
        #expect(RuleMatcher.compareVersions("14.0", "15.0") < 0)
        #expect(RuleMatcher.compareVersions("1.10", "1.9") > 0)
        #expect(RuleMatcher.compareVersions("1.2.3", "1.2.3") == 0)
    }

    @Test func combineWorstOfStatus() {
        #expect(RulesetEvaluator.combine(.compatible, .unsupported) == .unsupported)
        #expect(RulesetEvaluator.combine(.unknown, .compatible) == .unknown)
        #expect(RulesetEvaluator.combine(.partiallyCompatible, .compatible) == .partiallyCompatible)
    }
}
