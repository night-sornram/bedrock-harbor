import Foundation
import HarborDomain
import HarborCompatibility
import HarborPlatform

// MARK: - Composition bundle for workflows

public struct HarborServiceBundle: Sendable {
    public var metadata: any MetadataRepository
    public var credentials: any CredentialStore
    public var store: (any MinecraftStoreProvider)?
    public var auth: (any AuthenticationProvider)?
    public var downloads: (any DownloadManaging)?
    public var installer: (any MinecraftInstalling)?
    public var runtimeProvider: (any RuntimeProviding)?
    public var runtimeLauncher: (any RuntimeLaunching)?
    public var compatibility: any CompatibilityEvaluating
    public var worlds: (any WorldManaging)?
    public var content: (any ContentImporting)?
    public var diagnostics: (any DiagnosticsCollecting)?
    public var leases: any DataRootLeasing
    public var redactor: any Redacting
    public var paths: HarborPaths

    public init(
        metadata: any MetadataRepository,
        credentials: any CredentialStore,
        store: (any MinecraftStoreProvider)? = nil,
        auth: (any AuthenticationProvider)? = nil,
        downloads: (any DownloadManaging)? = nil,
        installer: (any MinecraftInstalling)? = nil,
        runtimeProvider: (any RuntimeProviding)? = nil,
        runtimeLauncher: (any RuntimeLaunching)? = nil,
        compatibility: any CompatibilityEvaluating = RulesetEvaluator(),
        worlds: (any WorldManaging)? = nil,
        content: (any ContentImporting)? = nil,
        diagnostics: (any DiagnosticsCollecting)? = nil,
        leases: any DataRootLeasing = DataRootLeaseCenter(),
        redactor: any Redacting = LogRedactor(),
        paths: HarborPaths
    ) {
        self.metadata = metadata
        self.credentials = credentials
        self.store = store
        self.auth = auth
        self.downloads = downloads
        self.installer = installer
        self.runtimeProvider = runtimeProvider
        self.runtimeLauncher = runtimeLauncher
        self.compatibility = compatibility
        self.worlds = worlds
        self.content = content
        self.diagnostics = diagnostics
        self.leases = leases
        self.redactor = redactor
        self.paths = paths
    }
}

// MARK: - Profile workflow

public struct ProfileWorkflow: Sendable {
    public let services: HarborServiceBundle

    public init(services: HarborServiceBundle) {
        self.services = services
    }

    public func listProfiles() async throws -> [Profile] {
        try await services.metadata.loadProfiles()
    }

    /// Duplicate settings create an empty data root unless copyWorlds is explicit.
    public func duplicate(
        profile: Profile,
        newName: String,
        copyWorlds: Bool
    ) async throws -> Profile {
        guard copyWorlds == false else {
            // World copy path is Phase 1+ with lease + backup guarantees.
            throw HarborError.unsupportedOperation(reason: "World-copy duplication is not enabled in the foundation build")
        }
        var copy = profile
        copy.id = UUID()
        copy.name = newName
        copy.dataRootID = UUID().uuidString.lowercased()
        copy.createdAt = Date()
        var all = try await services.metadata.loadProfiles()
        all.append(copy)
        try await services.metadata.saveProfiles(all)
        return copy
    }

    public func create(name: String, installationID: UUID?, runtimeReleaseID: String?) async throws -> Profile {
        let profile = Profile(
            name: name,
            selectedInstallationID: installationID,
            pinnedRuntimeReleaseID: runtimeReleaseID
        )
        var all = try await services.metadata.loadProfiles()
        all.append(profile)
        try await services.metadata.saveProfiles(all)
        try services.paths.ensurePrivateDirectoryLayout()
        let dataURL = services.paths.profileDataURL(dataRootID: profile.dataRootID)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        return profile
    }

    public func update(_ profile: Profile) async throws {
        var all = try await services.metadata.loadProfiles()
        guard let idx = all.firstIndex(where: { $0.id == profile.id }) else {
            throw HarborError.internalInconsistency(reason: "Profile not found")
        }
        all[idx] = profile
        try await services.metadata.saveProfiles(all)
    }

    public func delete(id: UUID) async throws {
        var all = try await services.metadata.loadProfiles()
        all.removeAll { $0.id == id }
        try await services.metadata.saveProfiles(all)
        // Intentionally does not delete worlds or installations.
    }
}

// MARK: - Compatibility + launch gating

public struct LaunchGateWorkflow: Sendable {
    public let services: HarborServiceBundle

    public init(services: HarborServiceBundle) {
        self.services = services
    }

    public func evaluate(
        profile: Profile,
        installation: InstalledMinecraft?,
        runtime: RuntimeInstallation?,
        patchIDs: [String] = []
    ) async throws -> CompatibilityReport {
        let env = CompatibilityEnvironment(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            processArchitecture: ProcessArchitectureProbe.currentArchitectureString,
            isTranslated: ProcessArchitectureProbe.isTranslated,
            gameBuildID: installation?.buildID,
            runtimeReleaseID: runtime?.releaseID,
            runtimeSHA256: runtime?.artifactSHA256,
            patchIDs: patchIDs,
            installationIntegrity: installation?.integrity ?? .unknown
        )
        _ = profile
        return try await services.compatibility.evaluate(environment: env)
    }

    public func assertLaunchAllowed(
        profile: Profile,
        installation: InstalledMinecraft?,
        runtime: RuntimeInstallation?
    ) async throws -> CompatibilityReport {
        let report = try await evaluate(profile: profile, installation: installation, runtime: runtime)
        if report.launchBlocked {
            let reason = report.checks.filter(\.blocksLaunch).map(\.detail).joined(separator: " ")
            throw HarborError.compatibilityBlocked(reason: reason.isEmpty ? report.overall.rawValue : reason)
        }
        return report
    }
}

// MARK: - Session coordinator (application-owned tasks)

public actor GameSessionCoordinator {
    public struct ActiveSession: Sendable {
        public var session: LaunchSession
        public var dataRootID: String
        public var leaseOwner: String
    }

    private let services: HarborServiceBundle
    private var active: ActiveSession?
    /// Set as the FIRST statement of `launch()` (before any await) and cleared
    /// on every exit path. Actors are reentrant, so `active == nil` alone lets
    /// a concurrent `launch()` interleave at any suspension point below and
    /// double-enter the launch pipeline; this flag closes that window.
    private var launchReserved = false

    public init(services: HarborServiceBundle) {
        self.services = services
    }

    public func activeSession() -> ActiveSession? { active }

    public func launch(
        profile: Profile,
        installation: InstalledMinecraft,
        runtime: RuntimeInstallation
    ) async throws -> LaunchSession {
        guard !launchReserved else { throw HarborError.gameRunning(profileID: profile.id) }
        launchReserved = true
        guard let launcher = services.runtimeLauncher else {
            launchReserved = false
            throw HarborError.feasibilityGateIncomplete(reason: "Runtime launcher is not composed")
        }
        let owner = "session-\(UUID().uuidString)"
        do {
            // Inside the do on purpose: the catch below owns launchReserved and
            // the lease, so a future throwing verify path releases them instead
            // of leaking the reservation for the rest of the app's life.
            let verified = try await Self.verifyInstallation(installation, services: services)
            guard verified.integrity == .verified else {
                throw HarborError.invalidPackage(
                    reason: "Game package not verified under \(installation.relativeGameDirectory). Place lib/arm64-v8a/libminecraftpe.so in BedrockHarbor/Installations."
                )
            }
            try await services.leases.acquire(dataRootID: profile.dataRootID, owner: owner)
            _ = try await LaunchGateWorkflow(services: services)
                .assertLaunchAllowed(profile: profile, installation: verified, runtime: runtime)
            let plan = try await launcher.prepareLaunchPlan(profile: profile, installation: verified, runtime: runtime)
            let session = try await launcher.start(plan: plan)
            active = ActiveSession(session: session, dataRootID: profile.dataRootID, leaseOwner: owner)
            // Success: the reservation is now owned by the observer below, which
            // clears it when the runtime CONFIRMS the process ended. Lease
            // release follows confirmed termination, not UI calls.
            observeTermination(
                launcher: launcher,
                sessionID: session.id,
                dataRootID: profile.dataRootID,
                leaseOwner: owner
            )
            return session
        } catch {
            // Manual release on every thrown-error path (deliberately no defer:
            // the success path hands the reservation to the observer instead).
            launchReserved = false
            await services.leases.release(dataRootID: profile.dataRootID, owner: owner)
            throw error
        }
    }

    /// Watches the runtime event stream until a terminal event (`.exited` /
    /// `.failed`), then releases the data-root lease and clears session state.
    private func observeTermination(
        launcher: any RuntimeLaunching,
        sessionID: UUID,
        dataRootID: String,
        leaseOwner: String
    ) {
        Task {
            for await event in launcher.events(sessionID: sessionID) {
                guard event.kind == .exited || event.kind == .failed else { continue }
                await self.sessionDidEnd(sessionID: sessionID, dataRootID: dataRootID, leaseOwner: leaseOwner)
                return
            }
            // Stream finished without a terminal event (launcher without event
            // support): cleanup is left to the reconcileExited() fallback.
        }
    }

    /// Idempotent cleanup. Only acts while `sessionID` is still the active
    /// session, so a stale observer (superseded by `reconcileExited()` or by a
    /// newer launch) can never clobber the new session's state or reservation.
    private func sessionDidEnd(sessionID: UUID, dataRootID: String, leaseOwner: String) async {
        guard active?.session.id == sessionID else { return }
        await services.leases.release(dataRootID: dataRootID, owner: leaseOwner)
        active = nil
        launchReserved = false
    }

    public static func verifyInstallation(
        _ installation: InstalledMinecraft,
        services: HarborServiceBundle
    ) async throws -> InstalledMinecraft {
        let gameDir = URL(fileURLWithPath: installation.relativeGameDirectory, isDirectory: true)
        let lib = gameDir.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so")
        var updated = installation
        if FileManager.default.isReadableFile(atPath: lib.path) {
            updated.integrity = .verified
            updated.packageReceipts = [lib.path]
            if installation.providerID.rawValue == "missing-game" {
                updated.providerID = ProviderID(rawValue: "harbor-install")
            }
        } else {
            updated.integrity = .failed
            updated.packageReceipts = []
        }
        if updated != installation {
            var all = (try? await services.metadata.loadInstallations()) ?? []
            if let idx = all.firstIndex(where: { $0.id == installation.id }) { all[idx] = updated }
            else { all.append(updated) }
            try? await services.metadata.saveInstallations(all)
        }
        return updated
    }

    public func requestStop() async throws {
        guard let current = active else { return }
        if let launcher = services.runtimeLauncher {
            try await launcher.requestTermination(sessionID: current.session.id)
        }
    }

    /// Fallback cleanup for launchers without event support. Idempotent and
    /// safe to call anytime: the primary path is the terminal-event observer
    /// spawned by `launch()`. Does nothing while a launch is merely in flight
    /// (no active session yet), so it can never clobber a reservation.
    public func reconcileExited() async {
        guard let current = active else { return }
        await sessionDidEnd(sessionID: current.session.id, dataRootID: current.dataRootID, leaseOwner: current.leaseOwner)
    }
}

// MARK: - Doctor / diagnostics workflow

public struct DiagnosticsWorkflow: Sendable {
    public let services: HarborServiceBundle

    public init(services: HarborServiceBundle) {
        self.services = services
    }

    public func collect() async throws -> DiagnosticsSnapshot {
        var findings: [DoctorFinding] = []

        let arch = ProcessArchitectureProbe.currentArchitectureString
        findings.append(
            DoctorFinding(
                id: "host.arch",
                title: "Process architecture",
                detail: "Architecture=\(arch), translated=\(ProcessArchitectureProbe.isTranslated)",
                severity: arch == "arm64" && !ProcessArchitectureProbe.isTranslated ? .ok : .warning
            )
        )

        findings.append(
            DoctorFinding(
                id: "host.os",
                title: "Operating system",
                detail: ProcessInfo.processInfo.operatingSystemVersionString,
                severity: .ok
            )
        )

        do {
            try services.paths.ensurePrivateDirectoryLayout()
            findings.append(
                DoctorFinding(
                    id: "storage.layout",
                    title: "Application directory layout",
                    detail: "Managed roots prepared under Application Support / Caches / Logs",
                    severity: .ok
                )
            )
        } catch {
            findings.append(
                DoctorFinding(
                    id: "storage.layout",
                    title: "Application directory layout",
                    detail: "Failed to prepare managed roots",
                    severity: .critical
                )
            )
        }

        let installations = (try? await services.metadata.loadInstallations()) ?? []
            .filter { $0.providerID.rawValue != "missing-game" }
        let verifiedInstalls = installations.filter { $0.integrity == .verified }
        findings.append(
            DoctorFinding(
                id: "game.installations",
                title: "Game installations",
                detail: verifiedInstalls.isEmpty
                    ? "No verified game package under BedrockHarbor/Installations"
                    : "\(verifiedInstalls.count) verified installation(s)",
                severity: verifiedInstalls.isEmpty ? .warning : .ok
            )
        )

        let runtimes = (try? await services.metadata.loadRuntimeInstallations()) ?? []
        findings.append(
            DoctorFinding(
                id: "runtime.installations",
                title: "Runtime installations",
                detail: runtimes.isEmpty
                    ? "No approved runtime installed yet"
                    : runtimes.map { "\($0.releaseID) \($0.health.rawValue)" }.joined(separator: "; "),
                severity: runtimes.isEmpty ? .unknown : .ok
            )
        )

        let report = RulesetEvaluator().evaluateSync(
            environment: CompatibilityEnvironment(
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                processArchitecture: arch,
                isTranslated: ProcessArchitectureProbe.isTranslated
            )
        )
        findings.append(
            DoctorFinding(
                id: "compat.ruleset",
                title: "Compatibility ruleset",
                detail: "revision=\(report.rulesetRevision) ageDays=\(report.rulesetAgeDays.map(String.init) ?? "unknown")",
                severity: (report.rulesetAgeDays ?? 0) > 180 ? .warning : .ok
            )
        )

        findings.append(
            DoctorFinding(
                id: "gate.feasibility",
                title: "Feasibility gate",
                detail: "Public MVP claims require sign-in → ownership → ARM64 package → runtime → local world. Not recorded on this machine yet.",
                severity: .warning
            )
        )

        let redacted = services.redactor.redact(
            findings.map { "\($0.severity.rawValue): \($0.title) — \($0.detail)" }.joined(separator: "\n")
        )

        return DiagnosticsSnapshot(
            findings: findings,
            rulesetRevision: report.rulesetRevision,
            redactedSummary: redacted
        )
    }
}

// MARK: - Fakes for tests / UI previews

public struct NoOpDownloadManager: DownloadManaging {
    public init() {}
    public func start(request: DownloadRequest, artifact: PackageDelivery.Artifact, authorizationHandle: String?) async throws -> URL {
        throw HarborError.feasibilityGateIncomplete(reason: "Download manager not implemented in foundation build")
    }
    public func progress(for id: UUID) -> AsyncStream<DownloadProgress> {
        AsyncStream { $0.finish() }
    }
    public func cancel(id: UUID) async {}
}

public struct UnavailableStoreProvider: MinecraftStoreProvider {
    public let providerID: ProviderID = .googlePlay
    public init() {}
    public func capabilities() async -> ProviderCapabilities {
        ProviderCapabilities(providerID: .googlePlay, supported: [], notes: ["Feasibility gate pending; provider not live"])
    }
    public func listKnownVersions() async throws -> [MinecraftVersion] { [] }
    public func checkEntitlement(accountID: UUID) async throws -> EntitlementResult {
        throw HarborError.feasibilityGateIncomplete(reason: "Entitlement checks require a live Play session")
    }
    public func resolveDelivery(accountID: UUID, buildID: MinecraftBuildID) async throws -> PackageDelivery {
        throw HarborError.feasibilityGateIncomplete(reason: "Delivery resolution requires a live Play session")
    }
}

public struct PlaceholderRuntimeProvider: RuntimeProviding {
    public init() {}
    public func discoverInstallations() async throws -> [RuntimeInstallation] { [] }
    public func approvedReleases() async throws -> [RuntimeRelease] { [] }
    public func install(release: RuntimeRelease, artifactURL: URL) async throws -> RuntimeInstallation {
        throw HarborError.feasibilityGateIncomplete(reason: "Runtime installation awaits approval catalog + gate evidence")
    }
    public func health(for installationID: UUID) async throws -> RuntimeHealth { .unknown }
}

public struct PlaceholderRuntimeLauncher: RuntimeLaunching {
    public init() {}
    public func prepareLaunchPlan(profile: Profile, installation: InstalledMinecraft, runtime: RuntimeInstallation) async throws -> LaunchPlan {
        throw HarborError.feasibilityGateIncomplete(reason: "Launch plans require a qualified runtime layout")
    }
    public func start(plan: LaunchPlan) async throws -> LaunchSession {
        throw HarborError.feasibilityGateIncomplete(reason: "Runtime process launch requires qualification")
    }
    public func events(sessionID: UUID) -> AsyncStream<RuntimeEvent> {
        AsyncStream { $0.finish() }
    }
    public func requestTermination(sessionID: UUID) async throws {}
}

public struct FoundationDiagnosticsCollector: DiagnosticsCollecting {
    public let workflow: DiagnosticsWorkflow
    public init(workflow: DiagnosticsWorkflow) { self.workflow = workflow }
    public func collect() async throws -> DiagnosticsSnapshot { try await workflow.collect() }
    public func exportPreview() async throws -> DiagnosticsSnapshot { try await workflow.collect() }
    public func exportBundle(to destinationDirectory: URL) async throws -> URL {
        let snapshot = try await workflow.collect()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let url = destinationDirectory.appendingPathComponent("doctor-preview.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        return url
    }
}

public enum CompositionRoot {
    public static func makeFoundationBundle(
        paths: HarborPaths? = nil,
        runtimeProvider: (any RuntimeProviding)? = nil,
        runtimeLauncher: (any RuntimeLaunching)? = nil
    ) throws -> HarborServiceBundle {
        let resolvedPaths = try paths ?? HarborPaths.live()
        try resolvedPaths.ensurePrivateDirectoryLayout()
        let metadata = FileMetadataRepository(directory: resolvedPaths.metadataDirectory)
        return HarborServiceBundle(
            metadata: metadata,
            credentials: KeychainCredentialStore(),
            store: UnavailableStoreProvider(),
            downloads: NoOpDownloadManager(),
            runtimeProvider: runtimeProvider ?? PlaceholderRuntimeProvider(),
            runtimeLauncher: runtimeLauncher ?? PlaceholderRuntimeLauncher(),
            compatibility: RulesetEvaluator(),
            leases: DataRootLeaseCenter(),
            redactor: LogRedactor(
                managedRootPaths: [
                    resolvedPaths.applicationSupportRoot.path,
                    resolvedPaths.cachesRoot.path,
                    resolvedPaths.logsRoot.path,
                ]
            ),
            paths: resolvedPaths
        )
    }
}
