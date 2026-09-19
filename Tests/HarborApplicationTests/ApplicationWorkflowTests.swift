import Testing
import Foundation
@testable import HarborApplication
import HarborDomain
import HarborPlatform
import HarborCompatibility

@Suite("Application workflows")
struct ApplicationWorkflowTests {
    private func makeServices() throws -> HarborServiceBundle {
        try makeServices(runtimeLauncher: PlaceholderRuntimeLauncher())
    }

    private func makeServices(runtimeLauncher: any RuntimeLaunching) throws -> HarborServiceBundle {
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
            runtimeLauncher: runtimeLauncher,
            compatibility: RulesetEvaluator(),
            paths: paths
        )
    }

    /// Polls `condition` until it holds or `timeout` elapses (20 ms steps).
    private func until(
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    /// Runs `launch` and reports whether it threw `HarborError.gameRunning`
    /// within a timeout (a launch that hangs or succeeds reports false). The
    /// probe task is intentionally NOT cancelled: under the pre-Task-2 code a
    /// racing launch parks in the fake launcher's suspended `start`, so the
    /// race must never depend on draining or cancelling that probe.
    private func throwsGameRunning(
        timeout: TimeInterval = 3,
        _ launch: @escaping @Sendable () async throws -> LaunchSession
    ) async -> Bool {
        let gate = OneShotGate()
        Task { @Sendable in
            var hit = false
            do {
                _ = try await launch()
            } catch let error as HarborError {
                if case .gameRunning = error { hit = true }
            } catch {}
            gate.fire(hit)
        }
        Task { @Sendable in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            gate.fire(false)
        }
        return await gate.wait()
    }

    /// A profile + verified installation pair pointing at a temp game directory.
    private func makeLaunchableFixture(name: String) throws -> (profile: Profile, installation: InstalledMinecraft) {
        let gameDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-game-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gameDir.appendingPathComponent("lib/arm64-v8a", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "fake-lib".write(
            to: gameDir.appendingPathComponent("lib/arm64-v8a/libminecraftpe.so"),
            atomically: true,
            encoding: .utf8
        )
        let profile = Profile(name: name)
        let installation = InstalledMinecraft(
            buildID: MinecraftBuildID(
                packageIdentifier: "com.mojang.minecraftpe",
                versionCode: 1,
                abi: .arm64v8a
            ),
            originalVersionName: "1.21",
            relativeGameDirectory: gameDir.path,
            integrity: .verified,
            providerID: .googlePlay
        )
        return (profile, installation)
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

    // MARK: - Session coordinator lifecycle (Task 2)

    @Test(.timeLimit(.minutes(1)))
    func duplicateConcurrentLaunchThrowsGameRunningWhileFirstInFlight() async throws {
        let launcher = ControlledRuntimeLauncher()
        await launcher.setSuspendStart(true)
        let services = try makeServices(runtimeLauncher: launcher)
        let coordinator = GameSessionCoordinator(services: services)
        let runtime = RuntimeInstallation(releaseID: "r1", relativeInstallPath: "Runtimes/r1", artifactSHA256: "00")
        let fixtureA = try makeLaunchableFixture(name: "A")
        let fixtureB = try makeLaunchableFixture(name: "B")

        let first = Task {
            try await coordinator.launch(
                profile: fixtureA.profile,
                installation: fixtureA.installation,
                runtime: runtime
            )
        }
        #expect(await until { await launcher.startCallCount == 1 })

        // While the first launch is awaiting the (suspended) fake launcher, a
        // duplicate launch — same profile or another one — must be rejected.
        let sameProfileRejected = await throwsGameRunning {
            try await coordinator.launch(
                profile: fixtureA.profile,
                installation: fixtureA.installation,
                runtime: runtime
            )
        }
        #expect(sameProfileRejected)
        let otherProfileRejected = await throwsGameRunning {
            try await coordinator.launch(
                profile: fixtureB.profile,
                installation: fixtureB.installation,
                runtime: runtime
            )
        }
        #expect(otherProfileRejected)

        await launcher.releaseStart()
        let session = try await first.value
        #expect(session.state == .running)
        // No rejected launch ever reached the launcher.
        #expect(await launcher.startCallCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func leaseAutoReleasesAfterConfirmedTerminalEvent() async throws {
        let launcher = ControlledRuntimeLauncher()
        let services = try makeServices(runtimeLauncher: launcher)
        let coordinator = GameSessionCoordinator(services: services)
        let runtime = RuntimeInstallation(releaseID: "r1", relativeInstallPath: "Runtimes/r1", artifactSHA256: "00")
        let fixture = try makeLaunchableFixture(name: "Auto")

        let session = try await coordinator.launch(
            profile: fixture.profile,
            installation: fixture.installation,
            runtime: runtime
        )
        #expect(await coordinator.activeSession() != nil)
        #expect(await services.leases.isHeld(dataRootID: fixture.profile.dataRootID))

        // Termination confirmed by the runtime event stream — not by a UI call.
        await launcher.emitTerminal(.exited, sessionID: session.id)
        #expect(await until { await coordinator.activeSession() == nil })
        #expect(!(await services.leases.isHeld(dataRootID: fixture.profile.dataRootID)))

        // Reservation cleared: a fresh launch goes through and also auto-releases.
        let second = try await coordinator.launch(
            profile: fixture.profile,
            installation: fixture.installation,
            runtime: runtime
        )
        #expect(await coordinator.activeSession()?.session.id == second.id)
        await launcher.emitTerminal(.failed, sessionID: second.id)
        #expect(await until { await coordinator.activeSession() == nil })
        #expect(!(await services.leases.isHeld(dataRootID: fixture.profile.dataRootID)))
    }

    @Test(.timeLimit(.minutes(1)))
    func failedLaunchClearsReservationForNextLaunch() async throws {
        let launcher = ControlledRuntimeLauncher()
        await launcher.failNextStart()
        let services = try makeServices(runtimeLauncher: launcher)
        let coordinator = GameSessionCoordinator(services: services)
        let runtime = RuntimeInstallation(releaseID: "r1", relativeInstallPath: "Runtimes/r1", artifactSHA256: "00")
        let fixture = try makeLaunchableFixture(name: "Retry")

        await #expect(throws: HarborError.self) {
            _ = try await coordinator.launch(
                profile: fixture.profile,
                installation: fixture.installation,
                runtime: runtime
            )
        }
        #expect(await coordinator.activeSession() == nil)

        // The failed attempt must not poison the coordinator: launching again works.
        let session = try await coordinator.launch(
            profile: fixture.profile,
            installation: fixture.installation,
            runtime: runtime
        )
        #expect(session.state == .running)
        #expect(await coordinator.activeSession() != nil)
    }
}

/// Fake runtime launcher for coordinator lifecycle tests: records calls, can
/// suspend `start` until the test releases it, can fail on demand, and emits
/// terminal runtime events only when the test says so.
private actor ControlledRuntimeLauncher: RuntimeLaunching {
    private var startCallCountStorage = 0
    private var suspendStarts = false
    private var throwNextStart = false
    private var suspendedStarts: [CheckedContinuation<LaunchSession, Error>] = []
    private var knownSessions: Set<UUID> = []
    private var lastEvents: [UUID: RuntimeEvent] = [:]
    private var eventContinuations: [UUID: [AsyncStream<RuntimeEvent>.Continuation]] = [:]

    init() {}

    var startCallCount: Int { startCallCountStorage }

    func setSuspendStart(_ suspended: Bool) { suspendStarts = suspended }
    func failNextStart() { throwNextStart = true }

    func releaseStart() {
        let waiting = suspendedStarts
        suspendedStarts = []
        for continuation in waiting {
            let session = LaunchSession(id: UUID(), profileID: UUID(), state: .running)
            knownSessions.insert(session.id)
            continuation.resume(returning: session)
        }
    }

    func emitTerminal(_ kind: RuntimeEvent.Kind, sessionID: UUID) {
        let event = RuntimeEvent(
            sessionID: sessionID,
            kind: kind,
            exitCode: kind == .exited ? 0 : 1
        )
        // Mirrors the real hub: a terminal that fires before the subscriber
        // attached is replayed from history instead of being lost.
        lastEvents[sessionID] = event
        guard let continuations = eventContinuations.removeValue(forKey: sessionID) else { return }
        for continuation in continuations {
            continuation.yield(event)
            continuation.finish()
        }
    }

    nonisolated func prepareLaunchPlan(
        profile: Profile,
        installation: InstalledMinecraft,
        runtime: RuntimeInstallation
    ) async throws -> LaunchPlan {
        LaunchPlan(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            environment: [:],
            gameDataDirectoryURL: FileManager.default.temporaryDirectory,
            cacheDirectoryURL: FileManager.default.temporaryDirectory,
            profileID: profile.id
        )
    }

    func start(plan: LaunchPlan) async throws -> LaunchSession {
        startCallCountStorage += 1
        if throwNextStart {
            throwNextStart = false
            throw HarborError.unsupportedRuntime(reason: "controlled launch failure")
        }
        if suspendStarts {
            return try await withCheckedThrowingContinuation { continuation in
                suspendedStarts.append(continuation)
            }
        }
        let session = LaunchSession(id: UUID(), profileID: plan.profileID, state: .running)
        knownSessions.insert(session.id)
        return session
    }

    nonisolated func events(sessionID: UUID) -> AsyncStream<RuntimeEvent> {
        AsyncStream { continuation in
            Task { await self.attachStream(sessionID: sessionID, continuation: continuation) }
        }
    }

    private func attachStream(
        sessionID: UUID,
        continuation: AsyncStream<RuntimeEvent>.Continuation
    ) {
        guard knownSessions.contains(sessionID) else {
            continuation.finish()
            return
        }
        if let last = lastEvents[sessionID] {
            continuation.yield(last)
            continuation.finish()
            return
        }
        continuation.yield(RuntimeEvent(sessionID: sessionID, kind: .running))
        eventContinuations[sessionID, default: []].append(continuation)
    }

    func requestTermination(sessionID: UUID) async throws {}
}

/// Single-use latch resuming exactly one `await` with the first result;
/// later fires are ignored. Keeps probe/timeout races from hanging the suite.
private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func fire(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard self.value == nil else { return }
        self.value = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if let value {
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
            }
        }
    }
}
