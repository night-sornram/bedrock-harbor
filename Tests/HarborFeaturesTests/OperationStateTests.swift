import Foundation
import Testing
@testable import HarborFeatures
import HarborApplication
import HarborCompatibility
import HarborDomain
import HarborPlatform

@MainActor
@Suite("Operation state machines")
struct OperationStateTests {

    // MARK: - OperationTracker phases

    @Test func trackerBeginsIdleAndWalksPhases() {
        let tracker = OperationTracker()
        #expect(tracker.phase == .idle)

        tracker.begin("Verifying package")
        #expect(tracker.phase == .working("Verifying package"))

        tracker.begin("Preparing compatibility")
        #expect(tracker.phase == .working("Preparing compatibility"))

        tracker.succeed("Minecraft running")
        #expect(tracker.phase == .done("Minecraft running"))

        tracker.reset()
        #expect(tracker.phase == .idle)
    }

    @Test func trackerFailureCarriesRecovery() {
        let tracker = OperationTracker()
        tracker.begin("Launching")
        tracker.fail("Launcher runtime missing", recovery: .reinstallRuntime)
        guard case .failed(let message, let recovery) = tracker.phase else {
            Issue.record("expected failed phase, got \(tracker.phase)")
            return
        }
        #expect(message == "Launcher runtime missing")
        #expect(recovery == .reinstallRuntime)
        // Recovery stays available until the next phase change.
        tracker.begin("Reinstalling")
        #expect(tracker.phase == .working("Reinstalling"))
    }

    // MARK: - Error → recovery mapping

    @Test func recoveryMappingForRepresentativeErrors() {
        #expect(OperationTracker.recovery(for: HarborError.unsupportedRuntime(reason: "helper resources missing"))
                == .reinstallRuntime)
        #expect(OperationTracker.recovery(for: HarborError.invalidPackage(reason: "libminecraftpe.so missing"))
                == .installGame)
        #expect(OperationTracker.recovery(for: HarborError.compatibilityBlocked(reason: "known-broken version"))
                == .importPackage)
        #expect(OperationTracker.recovery(for: HarborError.reauthenticationRequired(providerID: .googlePlay))
                == .signIn)
        // No recovery action for an already-running game or a plain network hiccup.
        #expect(OperationTracker.recovery(for: HarborError.gameRunning(profileID: UUID())) == nil)
    }

    @Test func shortMessagesAreShort() {
        let longReason = String(repeating: "detail ", count: 80)
        let runtimeMessage = OperationTracker.shortMessage(for: HarborError.unsupportedRuntime(reason: longReason))
        #expect(!runtimeMessage.isEmpty)
        #expect(runtimeMessage.count < 80, "failure surfaces must stay short; got: \(runtimeMessage)")

        #expect(OperationTracker.shortMessage(for: HarborError.invalidPackage(reason: "x")).contains("Minecraft"))
        #expect(OperationTracker.shortMessage(for: HarborError.compatibilityBlocked(reason: "x"))
                .contains("compatibility"))
        // Unknown errors fall back to localizedDescription, never empty.
        #expect(!OperationTracker.shortMessage(for: URLError(.notConnectedToInternet)).isEmpty)
    }

    // MARK: - LaunchProgress stage machine

    @Test func launchProgressStagesFromEventSequence() {
        // Pre-process local stages.
        #expect(LaunchProgress.verifyingPackage.label.contains("Verifying"))
        #expect(LaunchProgress.preparingCompatibility.label.contains("compatibility"))

        // Supervisor events drive the live stages.
        var stage: LaunchProgress? = .launching
        stage = LaunchProgress.applying(RuntimeEvent(sessionID: UUID(), kind: .started), to: stage)
        #expect(stage == .running(stage: "started"))
        stage = LaunchProgress.applying(RuntimeEvent(sessionID: UUID(), kind: .running), to: stage)
        #expect(stage == .running(stage: "running"))
        stage = LaunchProgress.applying(RuntimeEvent(sessionID: UUID(), kind: .stopping), to: stage)
        #expect(stage == .stopping)
        // A stray started after stopping must not resurrect a running stage.
        stage = LaunchProgress.applying(RuntimeEvent(sessionID: UUID(), kind: .running), to: stage)
        #expect(stage == .stopping)
    }

    @Test func terminalEventsResetStage() {
        for kind: RuntimeEvent.Kind in [.exited, .failed] {
            let stage = LaunchProgress.applying(
                RuntimeEvent(sessionID: UUID(), kind: kind, exitCode: 1),
                to: .running(stage: "running")
            )
            #expect(stage == nil, "\(kind.rawValue) is terminal — stage must reset")
        }
        #expect(LaunchProgress.isTerminal(RuntimeEvent(sessionID: UUID(), kind: .exited)))
        #expect(LaunchProgress.isTerminal(RuntimeEvent(sessionID: UUID(), kind: .failed)))
        #expect(!LaunchProgress.isTerminal(RuntimeEvent(sessionID: UUID(), kind: .running)))
    }

    @Test func progressTrackerAppliesEventsAndResets() {
        let tracker = LaunchProgressTracker()
        #expect(tracker.stage == nil)

        tracker.begin(.launching)
        #expect(tracker.stage == .launching)

        var terminal = tracker.apply(RuntimeEvent(sessionID: UUID(), kind: .started))
        #expect(!terminal)
        #expect(tracker.stage == .running(stage: "started"))

        terminal = tracker.apply(RuntimeEvent(sessionID: UUID(), kind: .failed, exitCode: 1, message: "signal 11"))
        #expect(terminal, "terminal event must report reset")
        #expect(tracker.stage == nil)
    }

    @Test func elapsedFormattingSanity() {
        #expect(LaunchProgressTracker.formatElapsed(0) == "0s")
        #expect(LaunchProgressTracker.formatElapsed(4.9) == "5s")
        #expect(LaunchProgressTracker.formatElapsed(59.4) == "59s")
        #expect(LaunchProgressTracker.formatElapsed(75) == "1m 15s")
        #expect(LaunchProgressTracker.formatElapsed(3599) == "59m 59s")
        #expect(LaunchProgressTracker.formatElapsed(3600) == "1h 00m 00s")
        #expect(LaunchProgressTracker.formatElapsed(7834) == "2h 10m 34s")
    }

    // MARK: - AppState event wiring (Play auto-restore)

    @Test func terminalRuntimeEventRestoresPlayAvailability() async throws {
        let services = try Self.makeServices()
        let app = AppState(services: services)
        await app.reload()

        // Simulate an in-flight session.
        app.launchInFlight = true
        app.isGameRunning = true
        app.playOperations.succeed("Minecraft running")

        let reset = app.applyRuntimeEvent(RuntimeEvent(sessionID: UUID(), kind: .exited, exitCode: 0))
        #expect(reset)
        #expect(!app.launchInFlight, "terminal event must restore the Play button")
        #expect(!app.isGameRunning)
        if case .done = app.playOperations.phase {} else {
            Issue.record("clean exit should read as done, got \(app.playOperations.phase)")
        }
    }

    @Test func failedRuntimeEventSurfacesFailure() async throws {
        let services = try Self.makeServices()
        let app = AppState(services: services)
        await app.reload()

        app.launchInFlight = true
        app.isGameRunning = true

        let reset = app.applyRuntimeEvent(
            RuntimeEvent(sessionID: UUID(), kind: .failed, exitCode: 11, message: "signal 11")
        )
        #expect(reset)
        #expect(!app.launchInFlight)
        #expect(!app.isGameRunning)
        guard case .failed = app.playOperations.phase else {
            Issue.record("crashed session should surface a failure, got \(app.playOperations.phase)")
            return
        }
    }

    /// Cancel belongs strictly to launch preparation. After Stop is pressed,
    /// `stopGame()` drops `isGameRunning` while `launchInFlight` stays set
    /// until the terminal event — that stopping window must NOT offer Cancel
    /// (nothing is cancellable anymore, and pressing it would overwrite the
    /// "Stopping Minecraft" label).
    @Test func cancelAvailableOnlyDuringPreparationNotStopping() async throws {
        let services = try Self.makeServices()
        let app = AppState(services: services)
        await app.reload()

        // Preparation: reserved, no process yet — Cancel available.
        app.launchInFlight = true
        app.isGameRunning = false
        app.launchProgress.begin(.verifyingPackage)
        #expect(app.canCancelLaunchPreparation)

        // Stopping window: Stop was pressed (isGameRunning false, stage
        // .stopping, reservation still held) — Cancel must stay hidden.
        app.launchProgress.begin(.stopping)
        #expect(!app.canCancelLaunchPreparation)

        // Terminal event: session over — Cancel hidden because nothing is in flight.
        _ = app.applyRuntimeEvent(RuntimeEvent(sessionID: UUID(), kind: .exited, exitCode: 0))
        #expect(!app.canCancelLaunchPreparation)

        // Fresh run reaches process creation: Stop's domain — Cancel hidden.
        app.launchInFlight = true
        app.isGameRunning = true
        app.launchProgress.begin(.running(stage: "running"))
        #expect(!app.canCancelLaunchPreparation)
    }

    // MARK: - Helpers

    private static func makeServices() throws -> HarborServiceBundle {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-opstate-\(UUID().uuidString)", isDirectory: true)
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
}
