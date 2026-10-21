#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoCoachingAbandonTests {
    @Test(arguments: ["none", "before", "after"])
    func gracefulOwnedExitPreservesBuffersButNeverErasesRevocation(abandon: String) async throws {
        var pcm: [Int32] = [-1, -1], control = pcm
        try #require(pipe(&pcm) == 0 && pipe(&control) == 0)
        defer { close(pcm[0]); close(control[0]) }
        let input = RightyoStdinWriter(input: pcm[1], exit: RightyoExitLatch(), timing: .init())
        let stream = AsyncThrowingStream<Data, any Error>.makeStream(), queued = RightyoByteCount()
        let revocation = RightyoOutputRevocation(), terminal = Data("authored-terminal".utf8)
        let writer = RightyoChildProcess.coachingWriter(control[1], input: input, continuation: stream.continuation,
                                                       revocation: revocation)
        defer { writer.close(); input.close(abandon: true) }
        queued.withLock { $0 += terminal.count }; stream.continuation.yield(terminal)
        if abandon == "before" { revocation.revoke() }
        writer.close()
        if abandon == "after" { revocation.revoke() }
        revocation.ownedGroupEnded(); stream.continuation.finish(throwing: RightyoChildError.transportLost)
        let lines = RightyoChildOutput(base: .init(stream: stream.stream, queued: queued),
                                       revocation: revocation, control: writer)
        var iterator = lines.makeAsyncIterator()
        if abandon == "none" { #expect(try await iterator.next() == terminal) }
        do { _ = try await iterator.next()
            Issue.record("Retired stream did not refuse after its allowed buffer")
        } catch { #expect(error as? RightyoChildError == .transportLost) }
    }

    @Test(arguments: [false, true])
    func gracefulCoachingEOFStillDeliversBufferedAndTerminalOutput(leaderExits: Bool) async throws {
        let fake = try FakeRightyo("""
        printf 'authored-buffered\\n'
        /bin/cat >/dev/null
        printf 'authored-terminal\\n'
        \(leaderExits ? "exit 0" : "exec /bin/sleep 60")
        """)
        defer { fake.cleanUp() }
        let child = try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config,
            session: UUID().uuidString.lowercased(), provenance: .synthetic, coaching: .init())
        do {
            try #require(await eventually { child.lines.base.queued.withLock { $0 > 0 } })
            child.closeInput(); child.closeInput()
            #expect(!child.write(Data([1, 0])))
            #expect(!child.sendCoachingControl(Data("{}".utf8), validUntil: .now.advanced(by: .seconds(1))))
            var iterator = child.lines.makeAsyncIterator()
            #expect(try await iterator.next() == Data("authored-buffered".utf8))
            #expect(try await iterator.next() == Data("authored-terminal".utf8))
        } catch { _ = await child.stop(); throw error }
        _ = await child.stop()
    }

    @Test func closedControlPeerCannotDeliverItsBufferedStdout() async throws {
        let fake = try FakeRightyo("""
        IFS= read -r control <&3
        exec 3<&-
        printf closed > closed-control
        printf 'authored-stale-output\\n'
        exec /bin/sleep 60
        """)
        defer { fake.cleanUp() }
        let child = try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config,
            session: UUID().uuidString.lowercased(), provenance: .synthetic, coaching: .init())
        do {
            #expect(child.sendCoachingControl(Data("{}".utf8), validUntil: .now.advanced(by: .seconds(1))))
            try #require(await eventually { (try? fake.recorded("closed-control")) == "closed" })
            var iterator = child.lines.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                Issue.record("Output from a child with a closed control peer was delivered")
            } catch { #expect(error as? RightyoChildError == .transportLost) }
        } catch { _ = await child.stop(); throw error }
        _ = await child.stop()
    }

    @Test func revokedSuspendedDeliveryRefusesLaterOutput() async throws {
        let stream = AsyncThrowingStream<Data, any Error>.makeStream()
        let revocation = RightyoOutputRevocation(), queued = RightyoByteCount()
        let lines = RightyoChildOutput(base: RightyoChildLines(stream: stream.stream, queued: queued),
                                       revocation: revocation)
        let waiter = Task { var iterator = lines.makeAsyncIterator(); return try await iterator.next() }
        try await Task.sleep(for: .milliseconds(10))
        revocation.revoke()
        queued.withLock { $0 += 2 }; stream.continuation.yield(Data([2, 0])); stream.continuation.finish()
        do {
            _ = try await waiter.value
            Issue.record("Suspended delivery crossed coaching revocation")
        } catch { #expect(error as? RightyoChildError == .transportLost) }
    }

    @Test func ordinaryFailureStillDeliversBufferedTerminalOutput() async throws {
        let stream = AsyncThrowingStream<Data, any Error>.makeStream(), queued = RightyoByteCount()
        let terminal = Data("synthetic-terminal".utf8)
        queued.withLock { $0 += terminal.count }; stream.continuation.yield(terminal)
        stream.continuation.finish(throwing: RightyoChildError.transportLost)
        let lines = RightyoChildOutput(base: RightyoChildLines(stream: stream.stream, queued: queued), revocation: nil)
        var iterator = lines.makeAsyncIterator()
        #expect(try await iterator.next() == terminal)
        do {
            _ = try await iterator.next()
            Issue.record("Ordinary failure disappeared")
        } catch { #expect(error as? RightyoChildError == .transportLost) }
    }

    @Test func controlFailureDiscardsBufferedOutputBeforeDelivery() async throws {
        var pcm: [Int32] = [-1, -1], control = pcm
        #expect(pipe(&pcm) == 0 && pipe(&control) == 0)
        defer { close(pcm[0]); close(control[0]) }
        let input = RightyoStdinWriter(input: pcm[1], exit: RightyoExitLatch(), timing: .init())
        let stream = AsyncThrowingStream<Data, any Error>.makeStream()
        let queued = RightyoByteCount(), stale = Data("authored-prior-advice".utf8)
        queued.withLock { $0 += stale.count }; stream.continuation.yield(stale)
        let revocation = RightyoOutputRevocation()
        let lines = RightyoChildOutput(base: RightyoChildLines(stream: stream.stream, queued: queued),
                                       revocation: revocation)
        let writer = RightyoChildProcess.coachingWriter(control[1], input: input, continuation: stream.continuation,
                                                       revocation: revocation)
        defer { writer.close(); input.close(abandon: true) }
        #expect(!writer.send(Data("{}\n{}".utf8), validUntil: .now.advanced(by: .seconds(1))))
        var iterator = lines.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Buffered output delivered after coaching revocation")
        } catch { #expect(error as? RightyoChildError == .transportLost) }
    }

    @Test func controlFailureReturnsBeforeAnyFurtherQueuedPCMWrite() throws {
        var pcm: [Int32] = [-1, -1], control = pcm
        #expect(pipe(&pcm) == 0 && pipe(&control) == 0)
        defer { close(pcm[0]); close(control[0]) }
        for fd in [pcm[1], control[1]] {
            #expect(fcntl(fd, F_SETNOSIGPIPE, 1) == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
        }
        #expect(fcntl(pcm[0], F_SETFL, O_NONBLOCK) == 0)
        let filler = Data(repeating: 127, count: 4_096)
        while filler.withUnsafeBytes({ write(pcm[1], $0.baseAddress, $0.count) }) > 0 {}
        #expect(errno == EAGAIN)
        let input = RightyoStdinWriter(input: pcm[1], exit: RightyoExitLatch(), timing: .init())
        let stream = AsyncThrowingStream<Data, any Error>.makeStream()
        let writer = RightyoChildProcess.coachingWriter(control[1], input: input, continuation: stream.continuation)
        defer { writer.close(); input.close(abandon: true) }
        #expect(input.write(Data(repeating: 18, count: 8_192)))
        usleep(20_000) // Controlled filled pipe: no bytes can progress before revocation.
        #expect(input.counters.writtenBytes == 0)
        #expect(!writer.send(Data("{}\n{}".utf8), validUntil: .now.advanced(by: .seconds(1))))
        #expect(!input.write(Data([2, 0])))
        let received = drain(pcm[0])
        #expect(!received.contains(18) && input.counters.writtenBytes == 0)
    }

    private func drain(_ fd: Int32) -> Data {
        var result = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { result.append(contentsOf: bytes.prefix(count)) } else if count == 0 { break } else {
                usleep(1_000)
            }
        }
        return result
    }
}
#endif
