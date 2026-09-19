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
                if await targetWindowOnScreen(processName: processName, ownerPID: ownerPID) {
                    await recorder.mark(stage)
                    return
                }
                try? await Task.sleep(for: pollInterval)
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
            pidsForName = await MainActor.run {
                NSWorkspace.shared.runningApplications
                    .filter { app in
                        app.localizedName?.caseInsensitiveCompare(processName) == .orderedSame
                            || app.executableURL?.lastPathComponent.caseInsensitiveCompare(processName) == .orderedSame
                    }
                    .reduce(into: Set<Int32>()) { $0.insert($1.processIdentifier) }
            }
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
