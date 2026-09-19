import Dispatch
import Foundation
import os

// MARK: - Launch timing stages

public enum LaunchTimingStage: String, Codable, Sendable, CaseIterable {
    case appLaunch, bootstrapDiscovery, runtimeInstall, packageAcquisition
    case compatibilityPreparation, launchPlanReady, processLaunched
    case gameWindowVisible, microsoftHelperSpawned, microsoftWindowVisible
    case sessionEnded
}

private extension LaunchTimingStage {
    /// `OSSignposter` interval names must be static strings; this gives every
    /// stage its own Instruments lane.
    var signpostName: StaticString {
        switch self {
        case .appLaunch: return "appLaunch"
        case .bootstrapDiscovery: return "bootstrapDiscovery"
        case .runtimeInstall: return "runtimeInstall"
        case .packageAcquisition: return "packageAcquisition"
        case .compatibilityPreparation: return "compatibilityPreparation"
        case .launchPlanReady: return "launchPlanReady"
        case .processLaunched: return "processLaunched"
        case .gameWindowVisible: return "gameWindowVisible"
        case .microsoftHelperSpawned: return "microsoftHelperSpawned"
        case .microsoftWindowVisible: return "microsoftWindowVisible"
        case .sessionEnded: return "sessionEnded"
        }
    }
}

// MARK: - Persisted record

public struct LaunchTimingRecord: Codable, Sendable, Equatable {
    public var id: UUID            // session id
    public var kind: String        // "appStart" | "launch" | "microsoft"
    public var startedAt: Date
    public var endedAt: Date?
    public var stageMarks: [String: Double]   // stage rawValue -> milliseconds since startedAt
    public var gameVersion: String?
    public var runtimeRelease: String?
    public var outcome: String?    // "ok" | "failed" | "cancelled"

    public init(
        id: UUID = UUID(),
        kind: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        stageMarks: [String: Double] = [:],
        gameVersion: String? = nil,
        runtimeRelease: String? = nil,
        outcome: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stageMarks = stageMarks
        self.gameVersion = gameVersion
        self.runtimeRelease = runtimeRelease
        self.outcome = outcome
    }
}

// MARK: - Recorder

/// Records launch-pipeline stage timings for one logical session at a time and
/// persists finished sessions as JSONL (newest `maxRecords` kept). This is
/// diagnostics only: every failure is swallowed so timing can never crash or
/// block the app.
public actor LaunchTimingRecorder {
    static let fileName = "launch-timings.jsonl"
    static let defaultMaxRecords = 100

    private let directory: URL
    private let maxRecords: Int
    private let signposter = OSSignposter(subsystem: "com.bedrockharbor.timing", category: "stages")

    private var current: LaunchTimingRecord?
    private var startUptimeNanos: UInt64 = 0

    /// - Parameter directory: directory for `launch-timings.jsonl` (created with intermediates).
    public init(directory: URL) {
        self.init(directory: directory, maxRecords: Self.defaultMaxRecords)
    }

    init(directory: URL, maxRecords: Int) {
        self.directory = directory
        self.maxRecords = maxRecords
    }

    /// Starts a new session, replacing any in-flight (not yet ended) session.
    public func begin(kind: String, gameVersion: String? = nil, runtimeRelease: String? = nil) {
        current = LaunchTimingRecord(
            kind: kind,
            startedAt: Date(),
            gameVersion: gameVersion,
            runtimeRelease: runtimeRelease
        )
        startUptimeNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// Records `stage` as milliseconds since `begin`. Ignored without an in-flight session.
    public func mark(_ stage: LaunchTimingStage) {
        guard var record = current else { return }
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- startUptimeNanos
        record.stageMarks[stage.rawValue] = Double(elapsedNanos) / 1_000_000
        current = record
        emitSignpost(for: stage)
    }

    /// Closes the in-flight session and persists it (trimmed to the newest `maxRecords`).
    public func end(outcome: String) {
        guard var record = current else { return }
        record.endedAt = Date()
        record.outcome = outcome
        current = nil
        persist(record)
    }

    /// Ends the in-flight session only when it is still `kind`. The recorder
    /// tracks one session at a time, so a game launch that started while the
    /// appStart session was open has already replaced it — ending "appStart"
    /// then must not cut the launch session short.
    public func end(kind: String, outcome: String) {
        guard current?.kind == kind else { return }
        end(outcome: outcome)
    }

    /// Reads the persisted JSONL records (oldest first). Empty when absent or unreadable.
    public static func recentRecords(directory: URL) -> [LaunchTimingRecord] {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data
            .split(separator: 0x0A)
            .compactMap { try? decoder.decode(LaunchTimingRecord.self, from: $0) }
    }

    // MARK: - Internals

    private func emitSignpost(for stage: LaunchTimingStage) {
        let state = signposter.beginInterval(stage.signpostName)
        signposter.endInterval(stage.signpostName, state)
    }

    /// Atomic rewrite of the whole (trimmed) array keeps the JSONL file small
    /// (≤ maxRecords lines) without needing an append-capable writer.
    private func persist(_ record: LaunchTimingRecord) {
        let fm = FileManager.default
        let url = directory.appendingPathComponent(Self.fileName)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var records = Self.recentRecords(directory: directory)
            records.append(record)
            if records.count > maxRecords {
                records = Array(records.suffix(maxRecords))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = Data()
            for item in records {
                data.append(try encoder.encode(item))
                data.append(0x0A)
            }
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Diagnostics must never take the app down: swallow.
        }
    }
}
