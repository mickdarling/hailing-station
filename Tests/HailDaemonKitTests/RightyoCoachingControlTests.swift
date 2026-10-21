#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

private final class CoachingControlFailures: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var total: Int { value.withLock { $0 } }
}

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoCoachingControlTests {
    private struct Channel {
        let writer: RightyoCoachingControlWriter
        let readEnd: Int32
        let failures: CoachingControlFailures
    }
    private func channel() throws -> Channel {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw RightyoChildError.transportLost }
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        _ = fcntl(ends[1], F_SETFL, O_NONBLOCK)
        _ = fcntl(ends[0], F_SETFL, O_NONBLOCK)
        let failures = CoachingControlFailures()
        return Channel(writer: RightyoCoachingControlWriter(ends[1]) { failures.increment() },
                       readEnd: ends[0], failures: failures)
    }

    @Test func longControlsStayOrderedBeyondAtomicPipeBound() throws {
        let connection = try channel()
        let writer = connection.writer, readEnd = connection.readEnd, failures = connection.failures
        defer { writer.close(); close(readEnd) }
        let first = Data(("{\"profile\":\"" + String(repeating: "a", count: 7_000) + "\"}").utf8)
        let second = Data(("{\"profile\":\"" + String(repeating: "b", count: 7_000) + "\"}").utf8)
        #expect(first.count > fpathconf(readEnd, _PC_PIPE_BUF))
        #expect(writer.send(first, validUntil: .now.advanced(by: .seconds(1))))
        #expect(writer.send(second, validUntil: .now.advanced(by: .seconds(1))))
        let expected = first + Data([10]) + second + Data([10])
        var actual = Data(), buffer = [UInt8](repeating: 0, count: 512)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while actual.count < expected.count, ContinuousClock.now < deadline {
            let count = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
            if count > 0 { actual.append(contentsOf: buffer.prefix(count)) } else {
                var ready = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                _ = poll(&ready, 1, 10)
            }
        }
        #expect(actual == expected && failures.total == 0)
    }

    @Test func expiredOversizedAndMultilineControlsFailClosedOnce() throws {
        for kind in 0..<3 {
            let connection = try channel()
            let writer = connection.writer, readEnd = connection.readEnd, failures = connection.failures
            defer { writer.close(); close(readEnd) }
            let data = kind == 1 ? Data(repeating: 65, count: 8_193)
                : Data((kind == 2 ? "{}\n{}" : "{}").utf8)
            let deadline = ContinuousClock.now.advanced(by: kind == 0 ? .seconds(-1) : .seconds(1))
            #expect(!writer.send(data, validUntil: deadline))
            #expect(!writer.send(Data("{}".utf8), validUntil: .now.advanced(by: .seconds(1))))
            #expect(failures.total == 1)
            let (count, error) = Self.readUntilEOF(readEnd)
            #expect(count == 0, "expected EOF on the revoked channel, read \(count) (errno \(error))")
        }
    }

    /// The writer closes its end synchronously, but the read end is nonblocking: while any other holder of the
    /// write end lingers, `read` returns -1 (EAGAIN), not EOF. In the parallel lane this was seen once as a flake.
    /// Waits up to 5 s for EOF instead of reading once; data, a hard error or a timeout still fail the test.
    static func readUntilEOF(_ descriptor: Int32) -> (count: Int, errno: Int32) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var byte: UInt8 = 0
        while true {
            let count = read(descriptor, &byte, 1)
            let error = errno
            guard count < 0, error == EAGAIN || error == EINTR, ContinuousClock.now < deadline else {
                return (count, count < 0 ? error : 0)
            }
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&ready, 1, 50)
        }
    }

    @Test func blockedPipeNeverExtendsOriginalControlDeadline() throws {
        let connection = try channel()
        let writer = connection.writer, readEnd = connection.readEnd, failures = connection.failures
        defer { writer.close(); close(readEnd) }
        // More than the kernel pipe plus application queue: either overflow or the original 250ms
        // deadline revokes the channel. Admission returns immediately, never waits on the consumer.
        let large = Data(repeating: 65, count: 8_000)
        let started = ContinuousClock.now
        for _ in 0..<16 { _ = writer.send(large, validUntil: started.advanced(by: .seconds(1))) }
        #expect(ContinuousClock.now - started < .seconds(1))
        let deadline = started.advanced(by: .seconds(1))
        while failures.total == 0, ContinuousClock.now < deadline { usleep(1_000) }
        #expect(failures.total == 1)
        #expect(!writer.send(Data("{}".utf8), validUntil: .now.advanced(by: .seconds(1))))
    }

    @Test func explicitLaunchIsCanonicalAndCannotShareOrdinaryReplyCapability() async throws {
        let fake = try FakeRightyo("echo started")
        defer { fake.cleanUp() }
        let launch = RightyoCoachingLaunch()
        #expect(throws: RightyoChildError.unsafeConfig) {
            try launch.arguments(session: "ambient-session", provenance: .synthetic)
        }
        #expect(throws: RightyoChildError.unsafeConfig) {
            try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config,
                session: UUID().uuidString.lowercased(), replyControl: true, coaching: launch)
        }
        let child = try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config,
            session: UUID().uuidString.lowercased(), provenance: .synthetic, coaching: launch)
        #expect(!child.reportReply(.started))
        child.abandonCoachingInput()
        #expect(!child.write(Data([1, 0])))
        #expect(!child.sendCoachingControl(Data("{}".utf8), validUntil: .now.advanced(by: .seconds(1))))
        _ = await child.stop()
    }

    @Test func idlePeerClosureRevokesWithoutAnotherSend() throws {
        let connection = try channel()
        defer { connection.writer.close() }
        close(connection.readEnd)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while connection.failures.total == 0, ContinuousClock.now < deadline { usleep(1_000) }
        #expect(connection.failures.total == 1)
        #expect(!connection.writer.send(Data("{}".utf8), validUntil: .now.advanced(by: .seconds(1))))
        #expect(connection.failures.total == 1)
    }

    @Test func idleWatcherDoesNotRetainItsWriterOrFailAfterExplicitClose() throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        let failures = CoachingControlFailures()
        var writer: RightyoCoachingControlWriter? = .init(ends[1]) { failures.increment() }
        weak let weakWriter = writer
        writer?.close()
        writer = nil
        #expect(weakWriter == nil)
        close(ends[0])
        usleep(60_000) // A queued idle probe must remain harmless after owned close/deinit.
        #expect(failures.total == 0)
    }
}
#endif
