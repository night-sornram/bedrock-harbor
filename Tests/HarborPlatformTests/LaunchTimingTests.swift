import Foundation
import Testing
@testable import HarborPlatform

@Suite("Launch timing instrumentation")
struct LaunchTimingTests {
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bh-launchtiming-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func beginMarkEndPersistsReadableRecord() async throws {
        let dir = makeTempDir()
        let recorder = LaunchTimingRecorder(directory: dir)

        await recorder.begin(kind: "appStart", gameVersion: "1.21.0", runtimeRelease: "rel-1")
        await recorder.mark(.appLaunch)
        try await Task.sleep(for: .milliseconds(10))
        await recorder.mark(.bootstrapDiscovery)
        try await Task.sleep(for: .milliseconds(10))
        await recorder.end(outcome: "ok")

        let records = LaunchTimingRecorder.recentRecords(directory: dir)
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.kind == "appStart")
        #expect(record.gameVersion == "1.21.0")
        #expect(record.runtimeRelease == "rel-1")
        #expect(record.outcome == "ok")
        #expect(record.endedAt != nil)
        #expect(record.endedAt! >= record.startedAt)

        let appLaunch = try #require(record.stageMarks[LaunchTimingStage.appLaunch.rawValue])
        let bootstrap = try #require(record.stageMarks[LaunchTimingStage.bootstrapDiscovery.rawValue])
        #expect(appLaunch >= 0)
        #expect(bootstrap >= appLaunch)
    }

    @Test func beginReplacesInFlightSession() async throws {
        let dir = makeTempDir()
        let recorder = LaunchTimingRecorder(directory: dir)

        await recorder.begin(kind: "appStart")
        await recorder.mark(.appLaunch)
        await recorder.begin(kind: "launch", gameVersion: "1.21.0")
        await recorder.mark(.launchPlanReady)
        await recorder.end(outcome: "ok")

        let records = LaunchTimingRecorder.recentRecords(directory: dir)
        #expect(records.count == 1)
        #expect(records.first?.kind == "launch")
        #expect(records.first?.gameVersion == "1.21.0")
        let marks = try #require(records.first?.stageMarks)
        #expect(marks[LaunchTimingStage.launchPlanReady.rawValue] != nil)
        #expect(marks[LaunchTimingStage.appLaunch.rawValue] == nil)
    }

    @Test func trimsToNewestRecordsAtCap() async throws {
        let dir = makeTempDir()
        let recorder = LaunchTimingRecorder(directory: dir, maxRecords: 3)

        for index in 0..<5 {
            await recorder.begin(kind: "session-\(index)")
            await recorder.end(outcome: "ok")
        }

        let records = LaunchTimingRecorder.recentRecords(directory: dir)
        #expect(records.count == 3)
        #expect(records.map(\.kind) == ["session-2", "session-3", "session-4"])
    }

    @Test func recentRecordsEmptyForMissingDirectory() {
        #expect(LaunchTimingRecorder.recentRecords(directory: makeTempDir()).isEmpty)
    }

    @Test func marksAndEndWithoutBeginAreIgnored() async {
        let dir = makeTempDir()
        let recorder = LaunchTimingRecorder(directory: dir)

        await recorder.mark(.appLaunch)
        await recorder.mark(.sessionEnded)
        await recorder.end(outcome: "ok")

        #expect(LaunchTimingRecorder.recentRecords(directory: dir).isEmpty)
    }

    @Test func marksAfterEndAreIgnored() async throws {
        let dir = makeTempDir()
        let recorder = LaunchTimingRecorder(directory: dir)

        await recorder.begin(kind: "appStart")
        await recorder.end(outcome: "cancelled")
        await recorder.mark(.appLaunch)

        let records = LaunchTimingRecorder.recentRecords(directory: dir)
        #expect(records.count == 1)
        #expect(records.first?.stageMarks.isEmpty == true)
    }

    @Test func stageRawValuesCoverLaunchPipeline() {
        #expect(LaunchTimingStage.allCases.count == 11)
        let rawValues = LaunchTimingStage.allCases.map(\.rawValue)
        for expected in ["appLaunch", "bootstrapDiscovery", "runtimeInstall", "packageAcquisition"] {
            #expect(rawValues.contains(expected))
        }
    }
}
