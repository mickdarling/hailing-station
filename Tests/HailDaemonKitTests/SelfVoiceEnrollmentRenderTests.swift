#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// Only synthetic shell fixtures execute here. The catalog and deadline are local test doubles.
@Suite(.timeLimit(.minutes(1)))
struct SelfVoiceEnrollmentRenderTests {
    private func prepare(_ files: EnrollmentFixture, script: String, clock: ProgressTestClock) throws
        -> SelfVoiceLaunchPreparation {
        let wrapper = files.root.appendingPathComponent("synthetic-renderer")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: wrapper)
        try #require(chmod(wrapper.path, 0o700) == 0)
        try files.write(path: wrapper.path)
        return SelfVoiceLaunchPreparation(enrollmentPath: files.file.path, directory: files.directory.path,
                                          clock: clock.clock, renderer: {
            EnrolledReplyRenderer(enrollment: $0, outputRoot: files.root, catalog: SyntheticSelfVoice())
        })
    }

    @Test func executesTheValidatedAbsolutePath() async throws {
        let files = try EnrollmentFixture()
        defer { files.remove() }
        try Data(count: 8 * 48_000).write(to: files.root.appendingPathComponent("silent.pcm"))
        let preparation = try prepare(files, script: #"exec /bin/cat "${0%/*}/silent.pcm""#, clock: ProgressTestClock())
        #expect(await preparation.prepare() == files.manifest)
        #expect(try files.readManifest().voices.map(\.id) == ["one"])
    }

    @Test func deadlineKillsAndReapsTheOwnedSyntheticChild() async throws {
        let files = try EnrollmentFixture(), clock = ProgressTestClock()
        defer { files.remove() }
        let ready = files.root.appendingPathComponent("ready").path, hold = files.root.appendingPathComponent("hold")
        try #require(mkfifo(ready, 0o600) == 0 && mkfifo(hold.path, 0o600) == 0)
        let descriptor = open(ready, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(descriptor >= 0)
        let started = AsyncStream<pid_t>.makeStream()
        let readable = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                                     queue: DispatchQueue(label: "test.enrollment.ready"))
        readable.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 64)
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            if let digits = String(bytes: bytes.prefix(count), encoding: .utf8),
               let pid = pid_t(digits.trimmingCharacters(in: .newlines)) { started.continuation.yield(pid) }
        }
        readable.setCancelHandler { close(descriptor) }
        readable.activate()
        defer { readable.cancel() }
        // Only shell builtins. The FIFO has no writer, so this child can finish only when the deadline signals it.
        let script = #"""
        echo "$$" > "${0%/*}/ready"
        read -r ignored < "${0%/*}/hold"
        """#
        let preparation = try prepare(files, script: script, clock: clock)
        let request = Task {
            defer { started.continuation.finish() }
            return await preparation.prepare()
        }
        var pids = started.stream.makeAsyncIterator()
        let pid = try #require(await pids.next())
        let worker = try #require(await preparation.inFlightWork)
        clock.advance(by: .seconds(20))
        #expect(await request.value == nil)
        #expect(await preparation.lastFailure == .timeout)
        await worker.value
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG), error = errno
        #expect(result == -1 && error == ECHILD)
        #expect(!FileManager.default.fileExists(atPath: files.manifest.path))
    }
}
#endif
