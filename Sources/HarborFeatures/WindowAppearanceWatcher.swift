import AppKit
import CoreGraphics
import Foundation
import HarborPlatform

/// Waits until a window owned by a given process appears on screen, then marks
/// the launch-timing stage that corresponds to "window visible". Only window
/// owner metadata (PID / owner name) is read — never window titles or contents —
/// so no screen-recording permission is required.
public enum WindowAppearanceWatcher {
    /// CGWindowList poll cadence.
    private static let pollInterval: Duration = .milliseconds(250)

    /// Polls `CGWindowListCopyWindowInfo` (on-screen windows only) every 250 ms
    /// until a window owned by `ownerPID` — or by any process whose name matches
    /// `processName` (resolved via `NSRunningApplication`) — appears, then records
    /// `stage` on `recorder`. Bounded by `timeout` (default 60 s). Runs off the
    /// main actor; the only main-actor hop is the `NSWorkspace` name→PID lookup.
    /// The returned task is an optional cancellation handle: watchers also stop
    /// on their own at the timeout, and marks after the recorder's session ended
    /// are ignored, so discarding the task is safe.
    @discardableResult
    public static func watch(
        processName: String? = nil,
        ownerPID: Int32? = nil,
        stage: LaunchTimingStage,
        recorder: LaunchTimingRecorder,
        timeout: TimeInterval = 60
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if Task.isCancelled { return }
                if await targetWindowOnScreen(processName: processName, ownerPID: ownerPID) {
                    await recorder.mark(stage)
                    return
                }
                do { try await Task.sleep(for: pollInterval) } catch { return }
            }
        }
    }

    /// Polls `NSWorkspace.runningApplications` (main-actor hop, same
    /// case-insensitive name resolution as window matching) until a process
    /// whose localized or executable name matches `processName` is running,
    /// then records `stage` and invokes `onSpawn` with the process identifier.
    /// Use this for helper processes that mark a stage the moment they spawn,
    /// before any window exists — e.g. to chain a pid-keyed `watch` for the
    /// helper's window. Bounded by `timeout`; runs off the main actor.
    @discardableResult
    public static func watchProcessSpawn(
        processName: String,
        stage: LaunchTimingStage,
        recorder: LaunchTimingRecorder,
        timeout: TimeInterval = 60,
        onSpawn: (@Sendable (Int32) -> Void)? = nil
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if Task.isCancelled { return }
                if let pid = await runningPIDs(named: processName).first {
                    await recorder.mark(stage)
                    onSpawn?(pid)
                    return
                }
                do { try await Task.sleep(for: pollInterval) } catch { return }
            }
        }
    }

    // MARK: - Internals

    private static func targetWindowOnScreen(processName: String?, ownerPID: Int32?) async -> Bool {
        guard
            let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID),
            let windowList = rawList as? [[String: Any]]
        else { return false }

        // Resolve the executable name to PIDs so windows whose CG owner name is
        // redacted still match. Small main-actor hop; NSWorkspace is main-only.
        var pidsForName: Set<Int32> = []
        if let processName, ownerPID == nil {
            pidsForName = await runningPIDs(named: processName)
        }
        for info in windowList {
            if matchesOwner(info, pid: ownerPID, name: processName) {
                return true
            }
            if !pidsForName.isEmpty,
               let windowPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
               pidsForName.contains(windowPID) {
                return true
            }
        }
        return false
    }

    /// PIDs of running applications whose localized or executable name matches
    /// `processName` (case-insensitive). Main-actor hop: NSWorkspace is main-only.
    private static func runningPIDs(named processName: String) async -> Set<Int32> {
        await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { app in
                    app.localizedName?.caseInsensitiveCompare(processName) == .orderedSame
                        || app.executableURL?.lastPathComponent.caseInsensitiveCompare(processName) == .orderedSame
                }
                .reduce(into: Set<Int32>()) { $0.insert($1.processIdentifier) }
        }
    }

    /// True when the CGWindowList entry is owned by `pid` **or** an owner whose
    /// name matches `name` (case-insensitive). Tolerates missing keys.
    static func matchesOwner(_ info: [String: Any], pid: Int32?, name: String?) -> Bool {
        if let pid,
           let windowPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
           windowPID == pid {
            return true
        }
        if let name, !name.isEmpty,
           let ownerName = info[kCGWindowOwnerName as String] as? String,
           ownerName.caseInsensitiveCompare(name) == .orderedSame {
            return true
        }
        return false
    }
}
