import Dispatch
import Foundation

// MARK: - Session log writer

/// Appends tagged process output to one session log file and keeps a bounded
/// tail of recent lines for diagnostics.
///
/// Sendability: every access to mutable state (file handle, ring buffer) goes
/// through `queue.sync`, so `@unchecked Sendable` is sound. `write(tag:data:)`
/// is only ever called from pipe readability handlers (plain dispatch threads)
/// or tests — never from an actor or the cooperative pool — so the synchronous
/// hop cannot deadlock and doubles as natural backpressure: dispatch does not
/// re-invoke a readability handler until the previous invocation returns, so
/// at most one chunk per pipe is in flight and buffering stays bounded.
final class ProcessLogWriter: @unchecked Sendable {
    static let maxRecentLines = 400
    static let maxRecentBytes = 8 * 1024 * 1024

    /// Hard cap for the on-disk log. Without it a firehose subprocess (2 s of
    /// `/usr/bin/yes` measures ~100 GB) can exhaust the disk; the recent-lines
    /// ring keeps the tail queryable even after the file stops growing.
    static let maxFileBytes = 32 * 1024 * 1024

    private let fileURL: URL
    private let queue = DispatchQueue(label: "harbor.process.log")

    // State below is touched only on `queue`.
    private var handle: FileHandle?
    private var fileSize: Int64 = 0
    private var closed = false
    private var ring: [String] = []
    private var ringBytes = 0
    private var lineRemainder = ""

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Appends `"[tag] "` plus `data` to the log file (up to the file cap) and
    /// to the recent-lines ring. Writes after `close()` are dropped.
    func write(tag: String, data: Data) {
        guard !data.isEmpty else { return }
        queue.sync {
            guard !closed else { return }
            appendToFile(tag: tag, data: data)
            appendToRing(tag: tag, data: data)
        }
    }

    /// Up to `limit` most recent complete lines, tag prefix included.
    func recentLines(limit: Int) -> [String] {
        queue.sync {
            guard limit > 0 else { return [] }
            return Array(ring.suffix(limit))
        }
    }

    /// Idempotent. Ring contents stay queryable after close.
    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: - Queue-confined internals

    private func appendToFile(tag: String, data: Data) {
        guard fileSize < Self.maxFileBytes else { return }
        do {
            if handle == nil {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                handle = try FileHandle(forWritingTo: fileURL)
                try handle?.seekToEnd()
                fileSize = Int64((try? handle?.offset()) ?? 0)
            }
            var payload = Data("[\(tag)] ".utf8)
            payload.append(data)
            let budget = Int(Self.maxFileBytes) - Int(fileSize)
            if payload.count > budget { payload = Data(payload.prefix(budget)) }
            try handle?.write(contentsOf: payload)
            fileSize += Int64(payload.count)
        } catch {
            // Diagnostics must never take down the process: drop the chunk.
        }
    }

    private func appendToRing(tag: String, data: Data) {
        // Invalid UTF-8 at chunk boundaries degrades to U+FFFD — acceptable for logs.
        let text = lineRemainder + String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lineRemainder = lines.removeLast()
        for line in lines {
            let tagged = "[\(tag)] \(line)"
            ring.append(tagged)
            ringBytes += tagged.utf8.count
        }
        while ring.count > Self.maxRecentLines
            || (ringBytes > Self.maxRecentBytes && ring.count > 1) {
            ringBytes -= ring.removeFirst().utf8.count
        }
    }
}

// MARK: - Pipe draining

/// Nonblocking pipe draining: installs a `readabilityHandler` so output is
/// consumed off the cooperative pool entirely. Must never be called from (or
/// hop onto) an actor — `drain` only installs the handler and returns.
enum ProcessPipeDrainer {
    /// Forwards `handle`'s output to `writer` under `tag` until EOF.
    /// Foundation invokes the handler when data is available (or at EOF), so
    /// `availableData` inside the handler never blocks; an empty chunk means
    /// EOF: remove the handler and close the read end.
    static func drain(_ handle: FileHandle, writer: ProcessLogWriter, tag: String) {
        handle.readabilityHandler = { @Sendable readHandle in
            let chunk = readHandle.availableData
            if chunk.isEmpty {
                readHandle.readabilityHandler = nil
                try? readHandle.close()
            } else {
                writer.write(tag: tag, data: chunk)
            }
        }
    }
}
