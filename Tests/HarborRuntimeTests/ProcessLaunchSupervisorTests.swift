import Testing
import Foundation
import HarborDomain
import HarborPlatform
@testable import HarborRuntime

@Suite("Process launch supervisor", .timeLimit(.minutes(2)))
struct ProcessLaunchSupervisorTests {
    private var tempDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessLaunchSupervisorTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makePaths(root: URL) -> HarborPaths {
        HarborPaths(
            applicationSupportRoot: root.appendingPathComponent("Support", isDirectory: true),
            cachesRoot: root.appendingPathComponent("Caches", isDirectory: true),
            logsRoot: root.appendingPathComponent("Logs", isDirectory: true)
        )
    }

    private func makePlan(executable: String, root: URL, arguments: [String] = []) -> LaunchPlan {
        LaunchPlan(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectoryURL: root,
            environment: ["PATH": "/usr/bin:/bin"],
            gameDataDirectoryURL: root.appendingPathComponent("data", isDirectory: true),
            cacheDirectoryURL: root.appendingPathComponent("cache", isDirectory: true),
            profileID: UUID()
        )
    }

    /// Collects events from `stream` until a terminal event or the stream ends.
    /// A timeout race keeps a broken (never-finishing) stream from hanging the suite.
    private func collectEvents(
        _ stream: AsyncStream<RuntimeEvent>,
        timeout: TimeInterval = 20
    ) async -> [RuntimeEvent] {
        await withTaskGroup(of: [RuntimeEvent]?.self) { group in
            group.addTask {
                var out: [RuntimeEvent] = []
                for await event in stream {
                    out.append(event)
                    if event.kind == .exited || event.kind == .failed { break }
                }
                return out
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    private func until(
        timeout: TimeInterval = 10,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    // MARK: - Immediate-exit subprocess

    @Test func immediateExitEmitsRunningThenExitedAndRecordsTiming() async throws {
        let root = tempDir
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.ensurePrivateDirectoryLayout()
        let supervisor = ProcessLaunchSupervisor(paths: paths)

        let session = try await supervisor.start(plan: makePlan(executable: "/bin/cat", root: root))
        let events = await collectEvents(supervisor.events(sessionID: session.id))

        #expect(events.map(\.kind).contains(.running))
        #expect(events.last?.kind == .exited)
        #expect(events.last?.exitCode == 0)

        // Task 1 integration: begin/mark/end must be wired to metadataDirectory.
        let recorded = await until {
            LaunchTimingRecorder.recentRecords(directory: paths.metadataDirectory)
                .contains { $0.kind == "launch" && $0.outcome != nil }
        }
        #expect(recorded)
        let records = LaunchTimingRecorder.recentRecords(directory: paths.metadataDirectory)
            .filter { $0.kind == "launch" }
        #expect(records.count == 1)
        #expect(records.first?.stageMarks[LaunchTimingStage.processLaunched.rawValue] != nil)
        #expect(records.first?.stageMarks[LaunchTimingStage.sessionEnded.rawValue] != nil)
        #expect(records.first?.outcome == "ok")
    }

    // MARK: - Finished sessions must not hang subscribers

    @Test func eventsForFinishedSessionCompleteWithoutHanging() async throws {
        let root = tempDir
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.ensurePrivateDirectoryLayout()
        let supervisor = ProcessLaunchSupervisor(paths: paths)

        let session = try await supervisor.start(plan: makePlan(executable: "/bin/cat", root: root))
        // Wait for the session to be finished (terminal event observed once).
        let first = await collectEvents(supervisor.events(sessionID: session.id))
        #expect(first.last?.kind == .exited || first.last?.kind == .failed)

        // A second subscription, opened after the session already finished, replays
        // the terminal event and finishes immediately.
        let replay = await collectEvents(supervisor.events(sessionID: session.id), timeout: 5)
        #expect(!replay.isEmpty)
        #expect(replay.last?.kind == .exited || replay.last?.kind == .failed)
    }

    // MARK: - Multi-subscriber fan-out (coordinator observer + UI listener)

    @Test(.timeLimit(.minutes(1)))
    func terminalEventFansOutToAllSubscribersOfLiveSession() async throws {
        let root = tempDir
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.ensurePrivateDirectoryLayout()
        let supervisor = ProcessLaunchSupervisor(paths: paths)

        // /bin/sleep keeps the session live long enough for a mid-session
        // UI-style subscriber to attach next to the coordinator-style one.
        let plan = makePlan(executable: "/bin/sleep", root: root, arguments: ["30"])
        let session = try await supervisor.start(plan: plan)

        // Subscriber 1: coordinator-style, attached right after launch.
        let coordinatorStream = supervisor.events(sessionID: session.id)
        try await Task.sleep(nanoseconds: 200_000_000) // let the attach task land

        // Subscriber 2: UI-style, attached mid-session while the game runs.
        let uiStream = supervisor.events(sessionID: session.id)
        try await Task.sleep(nanoseconds: 200_000_000)

        try await supervisor.requestTermination(sessionID: session.id)

        // BOTH subscribers must observe the terminal event: the coordinator's
        // lease release depends on its stream surviving the UI subscription.
        let coordinatorEvents = await collectEvents(coordinatorStream, timeout: 15)
        let uiEvents = await collectEvents(uiStream, timeout: 15)

        #expect(coordinatorEvents.map(\.kind).contains(.running))
        #expect(
            coordinatorEvents.last?.kind == .exited || coordinatorEvents.last?.kind == .failed,
            "coordinator-style subscriber lost the terminal event"
        )
        #expect(uiEvents.map(\.kind).contains(.stopping))
        #expect(
            uiEvents.last?.kind == .exited || uiEvents.last?.kind == .failed,
            "UI-style subscriber lost the terminal event"
        )
    }

    // MARK: - Noisy subprocess (regression fixture: large amounts of output)

    @Test(.timeLimit(.minutes(1)))
    func noisySubprocessDrainsWithoutDeadlockAndLogGrows() async throws {
        let root = tempDir
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.ensurePrivateDirectoryLayout()
        let supervisor = ProcessLaunchSupervisor(paths: paths)

        let session = try await supervisor.start(plan: makePlan(executable: "/usr/bin/yes", root: root))
        // Let it chatter for 2 s, then stop through the supervisor.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await supervisor.requestTermination(sessionID: session.id)

        let events = await collectEvents(supervisor.events(sessionID: session.id), timeout: 15)
        let kinds = events.map(\.kind)
        #expect(kinds.contains(.stopping))
        #expect(kinds.last == .exited || kinds.last == .failed)

        // The log file received output while the process was alive.
        let logURL = paths.sessionLogs.appendingPathComponent("session-\(session.id.uuidString).log")
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int64) ?? 0
        #expect(size > 65_536)

        // Timing outcome for a user-requested stop is "cancelled".
        let recorded = await until {
            LaunchTimingRecorder.recentRecords(directory: paths.metadataDirectory)
                .contains { $0.kind == "launch" && $0.outcome != nil }
        }
        #expect(recorded)
        #expect(
            LaunchTimingRecorder.recentRecords(directory: paths.metadataDirectory)
                .last(where: { $0.kind == "launch" })?.outcome == "cancelled"
        )
    }

    // MARK: - ProcessLogWriter ring bounds

    @Test func logWriterRecentLinesCappedAt400() throws {
        let dir = tempDir
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = ProcessLogWriter(fileURL: dir.appendingPathComponent("session.log"))

        for batch in 0..<20 {
            var chunk = Data()
            for line in 1...50 {
                chunk.append(Data("line-\(batch * 50 + line)\n".utf8))
            }
            writer.write(tag: "stdout", data: chunk) // 1000 unique lines total
        }

        let recent = writer.recentLines(limit: 500)
        #expect(recent.count == 400)
        #expect(recent.first == "[stdout] line-601")
        #expect(recent.last == "[stdout] line-1000")
        writer.close()
        writer.close() // idempotent
    }

    @Test func logWriterRingDropsOldestBeyondEightMegabytes() throws {
        let dir = tempDir
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = ProcessLogWriter(fileURL: dir.appendingPathComponent("session.log"))

        // 20 lines of ~1 MB each: total 20 MB must shrink to ≤ 8 MB (drop-oldest).
        let filler = String(repeating: "x", count: 1_048_576 - 1) + "\n"
        let chunk = Data(filler.utf8)
        for _ in 0..<20 { writer.write(tag: "stdout", data: chunk) }

        let recent = writer.recentLines(limit: 400)
        let total = recent.reduce(0) { $0 + $1.utf8.count }
        #expect(recent.count <= 8)
        #expect(total <= 8 * 1_048_576)
        writer.close()
    }

    @Test func logWriterPrefixesTagAndWritesFile() throws {
        let dir = tempDir
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("session.log")
        let writer = ProcessLogWriter(fileURL: logURL)

        writer.write(tag: "stdout", data: Data("hello\n".utf8))
        writer.write(tag: "stderr", data: Data("oops\n".utf8))
        writer.close()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(contents.contains("[stdout] hello\n"))
        #expect(contents.contains("[stderr] oops\n"))
        #expect(writer.recentLines(limit: 10) == ["[stdout] hello", "[stderr] oops"])
    }
}
