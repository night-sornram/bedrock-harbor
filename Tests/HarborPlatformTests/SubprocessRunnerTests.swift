import Foundation
import Testing
@testable import HarborPlatform

/// Bounded async subprocess runner: exit codes, output capture with a byte
/// cap, and timeout termination — all without blocking any thread.
/// Uses only stock system binaries (/bin/echo, /bin/false, /bin/sleep, /bin/zsh).
@Suite("HarborSubprocess runner")
struct SubprocessRunnerTests {
    @Test func echoCapturesStdoutAndExitCode() async throws {
        let result = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["harbor"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "harbor\n")
        #expect(result.stderr.isEmpty)
        #expect(!result.timedOut)
        #expect(!result.truncated)
    }

    @Test func timeoutTerminatesSleepingProcessPromptly() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.5
        )
        let elapsed = clock.now - start
        #expect(result.timedOut)
        #expect(result.exitCode != 0)
        #expect(elapsed < .seconds(2))
    }

    @Test func noisyOutputIsCappedAndTruncated() async throws {
        // ~2 MB of output against the 64 KB default cap: the regression fixture
        // for the disk-filling firehose class of helper (Task 2 lesson).
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", "for i in {1..2048}; do printf \"%1024s\" x; done"]
        )
        let elapsed = clock.now - start
        #expect(result.exitCode == 0)
        #expect(result.truncated)
        #expect(result.stdout.utf8.count <= 64_000)
        #expect(elapsed < .seconds(5))
    }

    @Test func falsePropagatesNonZeroExitCode() async throws {
        // /usr/bin/false on this macOS; /bin/false does not exist here.
        let result = try await HarborSubprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: []
        )
        #expect(result.exitCode == 1)
        #expect(!result.timedOut)
        #expect(!result.truncated)
    }
}
