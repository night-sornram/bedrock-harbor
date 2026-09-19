import Darwin
import Foundation

// MARK: - Result

/// Outcome of one `HarborSubprocess.run`. `stdout`/`stderr` are UTF-8 lossy
/// decodes of at most the first `outputLimit` bytes of each stream.
public struct SubprocessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    /// The timeout elapsed and the process was sent SIGTERM.
    public var timedOut: Bool
    /// Output hit the per-stream byte cap and was trimmed to the first bytes.
    public var truncated: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool, truncated: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.truncated = truncated
    }
}

// MARK: - Runner

/// Bounded async subprocess runner for short-lived helper tools (ditto,
/// hdiutil, mcpelauncher-extract). Never blocks a thread: output is captured
/// with `readabilityHandler` pipes (mirroring `ProcessIO.swift`), completion
/// comes from `terminationHandler`, and the timeout path signals by pid —
/// no `waitUntilExit`, no `readDataToEndFile`, nothing for the cooperative
/// pool to sleep on.
///
/// Output discipline (the Task 2 lesson): each stream keeps at most its first
/// `outputLimit` bytes (default 64 KB). The handler keeps consuming past the
/// cap and discards, so a firehose child can never wedge on a full pipe —
/// and can never fill this process's memory or disk either.
///
/// Caveat shared with the old blocking code: if the child spawns grandchildren
/// that inherit the output pipes and outlive it, EOF waits until they exit;
/// with a `timeout` set, the SIGTERM → SIGKILL escalation only targets the
/// direct child. None of Harbor's helper tools do this.
public enum HarborSubprocess {
    /// Runs `executable` and awaits its exit without blocking any thread.
    /// - Throws: only for launch failures (missing executable, bad working
    ///   directory, …) — a non-zero exit or timeout is reported in the result.
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        outputLimit: Int = 64_000,
        onStandardOutput: (@Sendable (Data) -> Void)? = nil,
        onStandardError: (@Sendable (Data) -> Void)? = nil
    ) async throws -> SubprocessResult {
        precondition(outputLimit >= 0, "outputLimit must not be negative")
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let stdoutTap = PipeTap(cap: outputLimit)
        let stderrTap = PipeTap(cap: outputLimit)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exitGate = TerminationGate()
        // Installed before launch so an exit racing pipe setup can never be missed.
        process.terminationHandler = { @Sendable exited in
            exitGate.complete(status: exited.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw error
        }
        let pid = process.processIdentifier

        drain(stdoutPipe.fileHandleForReading, into: stdoutTap, onChunk: onStandardOutput)
        drain(stderrPipe.fileHandleForReading, into: stderrTap, onChunk: onStandardError)

        // Timeout: SIGTERM first, SIGKILL after a grace period as the hang
        // safety net (a tool that ignores SIGTERM must still be bounded).
        // Signaling by pid keeps `Process` out of the @Sendable closure.
        let timeoutTask: Task<Void, Never>?
        if let timeout {
            let gate = exitGate
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                gate.signal(pid: pid, signal: SIGTERM, timedOut: true)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                gate.signal(pid: pid, signal: SIGKILL)
            }
        } else {
            timeoutTask = nil
        }
        defer { timeoutTask?.cancel() }

        let status = await withTaskCancellationHandler {
            await withCheckedContinuation { exitGate.install($0) }
        } onCancel: {
            exitGate.signal(pid: pid, signal: SIGTERM)
            Task.detached {
                try? await Task.sleep(for: .seconds(2))
                exitGate.signal(pid: pid, signal: SIGKILL)
            }
        }
        // Wait for both pipes to hit EOF so trailing output cannot race the snapshot.
        await withCheckedContinuation { stdoutTap.awaitEOF($0) }
        await withCheckedContinuation { stderrTap.awaitEOF($0) }
        try Task.checkCancellation()

        return SubprocessResult(
            exitCode: status,
            stdout: stdoutTap.text,
            stderr: stderrTap.text,
            timedOut: exitGate.timedOut,
            truncated: stdoutTap.truncated || stderrTap.truncated
        )
    }

    /// Installs a `readabilityHandler` that forwards chunks into `tap` until
    /// EOF (empty chunk): remove the handler, close the read end, signal EOF.
    /// Foundation only re-invokes the handler after the previous call returns,
    /// so at most one chunk per pipe is in flight. Same pattern as
    /// `ProcessIO.ProcessPipeDrainer`.
    private static func drain(_ handle: FileHandle, into tap: PipeTap, onChunk: (@Sendable (Data) -> Void)? = nil) {
        handle.readabilityHandler = { @Sendable readHandle in
            let chunk = readHandle.availableData
            if chunk.isEmpty {
                readHandle.readabilityHandler = nil
                try? readHandle.close()
                tap.reachEOF()
            } else {
                tap.append(chunk)
                onChunk?(chunk)
            }
        }
    }
}

// MARK: - Coordination primitives (lock-confined, @unchecked Sendable)

/// Exit coordination for one subprocess. `complete` may run before `install`
/// (a fast child can exit between launch and the await), so the first result
/// is buffered; the continuation resumes exactly once.
private final class TerminationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var status: Int32?
    private var timedOutFlag = false

    func install(_ continuation: CheckedContinuation<Int32, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if let status {
            continuation.resume(returning: status)
        } else {
            self.continuation = continuation
        }
    }

    func complete(status: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard self.status == nil else { return }
        self.status = status
        continuation?.resume(returning: status)
        continuation = nil
    }

    func signal(pid: pid_t, signal: Int32, timedOut: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard status == nil else { return }
        if timedOut { timedOutFlag = true }
        kill(pid, signal)
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutFlag
    }
}

/// One output stream's bounded capture: keeps the first `cap` bytes, flags
/// `truncated` when it discarded anything, decodes UTF-8 lossily, and gates on
/// EOF so a snapshot can never race a trailing chunk.
private final class PipeTap: @unchecked Sendable {
    private let cap: Int
    private let lock = NSLock()
    private var data = Data()
    private var exceededCap = false
    private var eof = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(cap: Int) {
        self.cap = cap
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        // Past the cap the chunk is dropped here — but the readability handler
        // keeps consuming, so the child never blocks on a full pipe.
        guard !exceededCap else { return }
        let remaining = cap - data.count
        if chunk.count > remaining {
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
            exceededCap = true
        } else {
            data.append(chunk)
        }
    }

    func reachEOF() {
        lock.lock()
        defer { lock.unlock() }
        eof = true
        continuation?.resume()
        continuation = nil
    }

    func awaitEOF(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if eof {
            continuation.resume()
        } else {
            self.continuation = continuation
        }
    }

    var truncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceededCap
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
