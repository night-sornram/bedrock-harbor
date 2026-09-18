import Testing
import Foundation
@testable import HarborApplication
import HarborDomain
import HarborPlatform
import HarborCompatibility

@Suite("Application workflows")
struct ApplicationWorkflowTests {
    private func makeServices() throws -> HarborServiceBundle {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-app-\(UUID().uuidString)", isDirectory: true)
        let paths = HarborPaths(
            applicationSupportRoot: base.appendingPathComponent("Support", isDirectory: true),
            cachesRoot: base.appendingPathComponent("Caches", isDirectory: true),
            logsRoot: base.appendingPathComponent("Logs", isDirectory: true)
        )
        try paths.ensurePrivateDirectoryLayout()
        return HarborServiceBundle(
            metadata: InMemoryMetadataRepository(),
            credentials: InMemoryCredentialStore(),
            store: UnavailableStoreProvider(),
            runtimeProvider: PlaceholderRuntimeProvider(),
            runtimeLauncher: PlaceholderRuntimeLauncher(),
            compatibility: RulesetEvaluator(),
            paths: paths
        )
    }

    @Test func createProfileUsesDistinctDataRoot() async throws {
        let services = try makeServices()
        let workflow = ProfileWorkflow(services: services)
        let a = try await workflow.create(name: "Survival", installationID: nil, runtimeReleaseID: nil)
        let b = try await workflow.create(name: "Creative", installationID: nil, runtimeReleaseID: nil)
        #expect(a.dataRootID != b.dataRootID)
        #expect(a.id != b.id)
        let all = try await workflow.listProfiles()
        #expect(all.count == 2)
    }

    @Test func duplicateProfileCreatesNewDataRoot() async throws {
        let services = try makeServices()
        let workflow = ProfileWorkflow(services: services)
        let original = try await workflow.create(name: "Main", installationID: nil, runtimeReleaseID: nil)
        let copy = try await workflow.duplicate(profile: original, newName: "Main Copy", copyWorlds: false)
        #expect(copy.dataRootID != original.dataRootID)
        #expect(copy.name == "Main Copy")
        await #expect(throws: HarborError.self) {
            _ = try await workflow.duplicate(profile: original, newName: "Nope", copyWorlds: true)
        }
    }

    @Test func launchGateBlocksUnsupportedHost() async throws {
        let services = try makeServices()
        let gate = LaunchGateWorkflow(services: services)
        let profile = Profile(name: "P")
        let installation = InstalledMinecraft(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 1,
                abi: .armeabiV7a
            ),
            originalVersionName: "1.0",
            relativeGameDirectory: "Installations/x",
            integrity: .verified,
            providerID: .googlePlay
        )
        await #expect(throws: HarborError.self) {
            _ = try await gate.assertLaunchAllowed(profile: profile, installation: installation, runtime: nil)
        }
    }

    @Test func doctorCollectsRedactedFindings() async throws {
        let services = try makeServices()
        let snapshot = try await DiagnosticsWorkflow(services: services).collect()
        #expect(!snapshot.findings.isEmpty)
        #expect(snapshot.findings.contains { $0.id == "gate.feasibility" })
        #expect(!snapshot.redactedSummary.isEmpty)
    }

    @Test func sessionCoordinatorRejectsLaunchWithoutQualifiedRuntime() async throws {
        let services = try makeServices()
        let coordinator = GameSessionCoordinator(services: services)
        let profile = Profile(name: "P")
        let installation = InstalledMinecraft(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 1,
                abi: .arm64v8a
            ),
            originalVersionName: "1.21",
            relativeGameDirectory: "Installations/x",
            integrity: .verified,
            providerID: .googlePlay
        )
        let runtime = RuntimeInstallation(releaseID: "r1", relativeInstallPath: "Runtimes/r1", artifactSHA256: "00")
        await #expect(throws: HarborError.self) {
            _ = try await coordinator.launch(profile: profile, installation: installation, runtime: runtime)
        }
        #expect(await coordinator.activeSession() == nil)
    }

    @Test func storeProviderAdvertisesNoLiveCapabilities() async throws {
        let provider = UnavailableStoreProvider()
        let caps = await provider.capabilities()
        #expect(caps.supported.isEmpty)
        #expect(caps.notes.contains { $0.contains("Feasibility") })
    }

    @Test func browserCallbackValidatorRejectsMismatchedScheme() throws {
        let request = BrowserAuthRequest(
            kind: .googlePlayEmbedded,
            permittedHostSuffixes: ["accounts.google.com"],
            callbackScheme: "bedrockharbor",
            callbackHost: "oauth",
            callbackPathPrefix: "/callback"
        )
        let good = URL(string: "bedrockharbor://oauth/callback?code=1")!
        let badScheme = URL(string: "https://evil.example/callback")!
        #expect(throws: HarborError.self) {
            try BrowserAuthValidator.validateCallback(url: badScheme, request: request)
        }
        try BrowserAuthValidator.validateCallback(url: good, request: request)
        #expect(BrowserAuthValidator.isPermittedNavigation(url: URL(string: "https://accounts.google.com/ServiceLogin")!, request: request))
        #expect(BrowserAuthValidator.isPermittedNavigation(url: good, request: request))
        #expect(!BrowserAuthValidator.isPermittedNavigation(url: URL(string: "https://evil.com/")!, request: request))
    }
}
