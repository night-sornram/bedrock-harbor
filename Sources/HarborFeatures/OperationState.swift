import Foundation
import HarborDomain
import Observation

// MARK: - OperationTracker

/// Structured replacement for the old `AppState.status` string: every action
/// reports its phase here, and failures carry a typed recovery action the UI
/// renders as a button. One tracker per UI concern (play, install, accounts,
/// maintenance, diagnostics) so sections never overwrite each other.
@MainActor
@Observable
public final class OperationTracker {
    public enum Phase: Equatable {
        case idle
        case working(String /*stage label*/)
        case done(String)
        case failed(String, recovery: Recovery?)
    }

    public enum Recovery: Equatable {
        case installGame
        case signIn
        case signInFresh
        case importPackage
        case rescan
        case reinstallRuntime
        case runDoctor
        case openSettings

        /// Button title for the recovery action.
        public var title: String {
            switch self {
            case .installGame: return "Install Minecraft"
            case .signIn: return "Sign in with Google Play"
            case .signInFresh: return "Sign in again (fresh)"
            case .importPackage: return "Import a supported package…"
            case .rescan: return "Rescan packages"
            case .reinstallRuntime: return "Reinstall runtime"
            case .runDoctor: return "Run Doctor"
            case .openSettings: return "Open Settings"
            }
        }
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    /// Enters (or advances within) the working phase. Repeated calls just
    /// update the stage label — long operations stream their stage names here.
    public func begin(_ stageLabel: String) {
        phase = .working(stageLabel)
    }

    public func succeed(_ message: String) {
        phase = .done(message)
    }

    public func fail(_ message: String, recovery: Recovery? = nil) {
        phase = .failed(message, recovery: recovery)
    }

    public func reset() {
        phase = .idle
    }

    public var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    // MARK: Error mapping

    /// Typed recovery action for a thrown error, or nil when there is nothing
    /// better to offer than trying again.
    public static func recovery(for error: Error) -> Recovery? {
        guard let harbor = error as? HarborError else { return nil }
        switch harbor {
        case .unsupportedRuntime, .integrityFailure:
            return .reinstallRuntime
        case .invalidPackage:
            return .installGame
        case .compatibilityBlocked:
            return .importPackage
        case .reauthenticationRequired:
            return .signIn
        default:
            return nil
        }
    }

    /// Short, user-facing explanation for a thrown error. Failure surfaces
    /// show one line plus a recovery button — never a paragraph.
    public static func shortMessage(for error: Error) -> String {
        guard let harbor = error as? HarborError else {
            return error.localizedDescription
        }
        switch harbor {
        case .unsupportedRuntime:
            return "Launcher runtime is missing or damaged."
        case .invalidPackage:
            return "Minecraft package is missing or not verified."
        case .compatibilityBlocked:
            return "This Minecraft version is blocked by compatibility rules."
        case .reauthenticationRequired:
            return "Google Play sign-in is needed again."
        case .gameRunning:
            return "A game session is already running."
        default:
            let text = harbor.localizedDescription
            return text.count <= 120 ? text : String(text.prefix(117)) + "…"
        }
    }
}

// MARK: - LaunchProgress

/// Typed live-stage value for a launch. Local preparation stages are set by
/// the launch flow; the runtime stages are driven by supervisor
/// `RuntimeEvent`s, so Play auto-restores the moment the game exits.
public enum LaunchProgress: Equatable, Sendable {
    case verifyingPackage
    case preparingCompatibility
    case checkingRuntime
    case launching
    case running(stage: String /*runtime event kind*/)
    case stopping

    public var label: String {
        switch self {
        case .verifyingPackage: return "Verifying game package"
        case .preparingCompatibility: return "Preparing compatibility"
        case .checkingRuntime: return "Checking launcher runtime"
        case .launching: return "Launching Minecraft"
        case .running(let stage): return "Minecraft running (\(stage))"
        case .stopping: return "Stopping Minecraft"
        }
    }

    /// Next stage for a supervisor event. Returns nil for terminal events —
    /// the caller must treat that as "the launch pipeline ended" and restore
    /// Play availability.
    public static func applying(_ event: RuntimeEvent, to stage: LaunchProgress?) -> LaunchProgress? {
        switch event.kind {
        case .started, .running:
            // Terminal-adjacent protection: once stopping, a late "running"
            // event must not resurrect a running stage.
            if stage == .stopping { return .stopping }
            return .running(stage: event.kind.rawValue)
        case .stopping:
            return .stopping
        case .exited, .failed:
            return nil
        }
    }

    public static func isTerminal(_ event: RuntimeEvent) -> Bool {
        event.kind == .exited || event.kind == .failed
    }
}

/// Observable holder for the current `LaunchProgress` plus a monotonic start
/// instant for the elapsed-seconds readout.
@MainActor
@Observable
public final class LaunchProgressTracker {
    public private(set) var stage: LaunchProgress?
    public private(set) var startedAt: ContinuousClock.Instant?

    private let clock = ContinuousClock()

    public func begin(_ stage: LaunchProgress) {
        if startedAt == nil { startedAt = clock.now }
        self.stage = stage
    }

    public func clear() {
        stage = nil
        startedAt = nil
    }

    /// Applies a supervisor event. Returns true when the event was terminal
    /// (stage cleared — the caller resets Play availability).
    @discardableResult
    public func apply(_ event: RuntimeEvent) -> Bool {
        if LaunchProgress.isTerminal(event) {
            clear()
            return true
        }
        if let next = LaunchProgress.applying(event, to: stage) {
            stage = next
        }
        return false
    }

    /// Seconds since the tracked stage sequence began (monotonic clock), or
    /// nil when nothing is in flight.
    public func elapsedSeconds() -> Double? {
        guard let startedAt else { return nil }
        let duration = clock.now - startedAt
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// "12s" / "1m 05s" / "2h 10m 34s" — whole seconds only; the UI ticks at
    /// 1 Hz so sub-second precision would just flicker.
    public static func formatElapsed(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}
