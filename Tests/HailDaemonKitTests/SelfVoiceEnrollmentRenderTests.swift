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

    private static let holdingDescendant = #"""
    /usr/bin/perl -e '
        use Errno qw(EPIPE);
        my ($root, $wrapper) = @ARGV;
        chdir $root or die;
        $SIG{PIPE} = "IGNORE";
        open my $events, ">", "ready" or die;
        syswrite($events, "$wrapper\n") or die;
        open my $gate, "<", "hold" or die;
        defined(readline($gate)) or die;
        sub probe {
            my ($pipe) = @_;
            return "open" if defined(syswrite($pipe, "x"));
            return $! == EPIPE ? "EPIPE" : "error";
        }
        my $result = probe(\*STDOUT) . " " . probe(\*STDERR);
        syswrite($events, "$result\n") or die;
    ' "${0%/*}" "$$" &
    wait
    """#

    @Test func deadlineRetiresBothReadersWhileDescendantHoldsTheirWriteEnds() async throws {
        let files = try EnrollmentFixture(), clock = ProgressTestClock()
        defer { files.remove() }
        let gates = try PipeGates(files.root)
        defer { gates.closeGates() }
        let preparation = try prepare(files, script: Self.holdingDescendant, clock: clock)
        let request = Task { await preparation.prepare() }
        var events = gates.messages.stream.makeAsyncIterator()
        let line = try #require(await events.next())
        let pid = try #require(pid_t(line))
        let worker = try #require(await preparation.inFlightWork)
        clock.advance(by: .seconds(20))
        #expect(await request.value == nil)
        #expect(await preparation.lastFailure == .timeout)
        Task {
            await worker.value
            gates.messages.continuation.yield("retired")
        }
        try #require(await events.next() == "retired")
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG), error = errno
        #expect(result == -1 && error == ECHILD)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: files.root.path)
            .contains { $0.hasPrefix("hailing-reply-job-") })
        gates.releaseDescendant()
        #expect(await events.next() == "EPIPE EPIPE")
        #expect(!FileManager.default.fileExists(atPath: files.manifest.path))
    }
}

/// Messages have one writer at a time. The next write is gated on delivery of the previous message.
private final class PipeGates: Sendable {
    let messages = AsyncStream<String>.makeStream()
    private let hold: Int32
    private let readable: any DispatchSourceRead

    init(_ root: URL) throws {
        let ready = root.appendingPathComponent("ready").path, gate = root.appendingPathComponent("hold").path
        try #require(mkfifo(ready, 0o600) == 0 && mkfifo(gate, 0o600) == 0)
        let descriptor = open(ready, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(descriptor >= 0)
        let writer = open(gate, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard writer >= 0 else { close(descriptor); throw CocoaError(.fileWriteUnknown) }
        hold = writer
        let queue = DispatchQueue(label: "test.enrollment.ready")
        readable = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readable.setEventHandler { [messages] in
            var bytes = [UInt8](repeating: 0, count: 64)
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0, let line = String(bytes: bytes.prefix(count), encoding: .utf8) {
                messages.continuation.yield(line.trimmingCharacters(in: .newlines))
            }
        }
        readable.setCancelHandler { close(descriptor) }
        readable.activate()
        // A regression may strand the worker. End the observation so the test fails and releases the descendant.
        queue.asyncAfter(deadline: .now() + 10) { [messages] in messages.continuation.finish() }
    }

    func releaseDescendant() { _ = write(hold, "\n", 1) }

    func closeGates() {
        releaseDescendant()
        close(hold)
        readable.cancel()
        messages.continuation.finish()
    }
}
#endif
