import CoreGraphics
import Foundation
import Testing
import HarborPlatform
@testable import HarborFeatures

@Suite("Window appearance watcher matching")
struct WindowAppearanceWatcherTests {
    /// Mirrors the dictionaries CGWindowListCopyWindowInfo produces
    /// (NSNumber-backed PID, string-backed owner name).
    private func windowInfo(pid: Int32?, ownerName: String?) -> [String: Any] {
        var info: [String: Any] = [:]
        if let pid { info[kCGWindowOwnerPID as String] = NSNumber(value: pid) }
        if let ownerName { info[kCGWindowOwnerName as String] = ownerName }
        return info
    }

    @Test func matchesByOwnerPID() {
        let info = windowInfo(pid: 4242, ownerName: "Minecraft")
        #expect(WindowAppearanceWatcher.matchesOwner(info, pid: 4242, name: nil))
        #expect(!WindowAppearanceWatcher.matchesOwner(info, pid: 9999, name: nil))
    }

    @Test func matchesByOwnerNameCaseInsensitively() {
        let info = windowInfo(pid: 4242, ownerName: "Minecraft")
        #expect(WindowAppearanceWatcher.matchesOwner(info, pid: nil, name: "minecraft"))
        #expect(!WindowAppearanceWatcher.matchesOwner(info, pid: nil, name: "Chess"))
    }

    @Test func pidOrNameIsEnoughToMatch() {
        let info = windowInfo(pid: 4242, ownerName: "Minecraft")
        #expect(WindowAppearanceWatcher.matchesOwner(info, pid: 9999, name: "Minecraft"))
        #expect(!WindowAppearanceWatcher.matchesOwner(info, pid: 9999, name: "Chess"))
    }

    @Test func emptyOrPartialInfoNeverMatchesAndDoesNotCrash() {
        #expect(!WindowAppearanceWatcher.matchesOwner([:], pid: nil, name: nil))
        #expect(!WindowAppearanceWatcher.matchesOwner([:], pid: 1, name: "Anything"))
        let noName = windowInfo(pid: 7, ownerName: nil)
        #expect(!WindowAppearanceWatcher.matchesOwner(noName, pid: nil, name: "Minecraft"))
        let noPID = windowInfo(pid: nil, ownerName: "Minecraft")
        #expect(WindowAppearanceWatcher.matchesOwner(noPID, pid: nil, name: "Minecraft"))
    }

    @Test func plainIntPIDValueIsAccepted() {
        let info = [kCGWindowOwnerPID as String: Int32(4242)]
        #expect(WindowAppearanceWatcher.matchesOwner(info, pid: 4242, name: nil))
    }

    @Test func cancelledWatcherStopsPromptlyInsteadOfPollingToDeadline() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-watcher-cancel-\(UUID().uuidString)", isDirectory: true)
        let recorder = LaunchTimingRecorder(directory: dir)

        // PID -1 never owns a window, so without cancellation this watcher
        // would keep polling CGWindowList until the full 10 s deadline.
        let watchTask = WindowAppearanceWatcher.watch(
            ownerPID: -1,
            stage: .gameWindowVisible,
            recorder: recorder,
            timeout: 10
        )
        watchTask.cancel()

        let clock = ContinuousClock()
        let start = clock.now
        await watchTask.value
        let elapsed = clock.now - start

        #expect(elapsed < .seconds(5))
    }
}
