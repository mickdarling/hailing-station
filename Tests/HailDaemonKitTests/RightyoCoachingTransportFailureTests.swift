#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoCoachingTransportFailureTests {
    @Test(arguments: [false, true], [false, true])
    func stdinFailureRevokesOnlyCoachingOutput(coaching: Bool, buffered: Bool) async throws {
        let fake = try FakeRightyo("""
        exec 0<&-
        printf 'ready\\n'
        \(buffered ? "printf 'authored-stale\\n'" : "")
        IFS= read -r token < release
        \(buffered ? "" : "printf 'authored-stale\\n'")
        printf 1 > emitted
        exec /bin/sleep 60
        """)
        defer { fake.cleanUp() }
        let release = fake.directory.appendingPathComponent("release")
        try #require(mkfifo(release.path, 0o600) == 0)
        let child = try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config,
            session: UUID().uuidString.lowercased(), provenance: .synthetic,
            timing: .init(eofGrace: 0.05, termGrace: 0.05), coaching: coaching ? .init() : nil)
        do {
            var iterator = child.lines.makeAsyncIterator()
            let ready: Data? = try await iterator.next()
            try #require(ready == Data("ready".utf8))
            if buffered {
                while child.lines.base.queued.withLock({ $0 }) == 0 {
                    try Task.checkCancellation(); await Task.yield()
                }
            }
            try await observeFailureAndRelease(child, fake: fake)
            if coaching {
                do { _ = try await iterator.next()
                    Issue.record("Lost coaching stdin still delivered stdout")
                } catch { #expect(error as? RightyoChildError == .transportLost) }
            } else {
                let line: Data? = try await iterator.next()
                #expect(line == Data("authored-stale".utf8))
            }
        } catch { _ = await child.stop(); throw error }
        _ = await child.stop()
    }

    private func observeFailureAndRelease(_ child: RightyoChildProcess, fake: FakeRightyo) async throws {
        let frame = Data([1, 0])
        try #require(child.write(frame)) // Queue admission precedes the asynchronous EPIPE.
        // Only failure can reject this valid frame: no local close, and the child is held alive at the FIFO.
        // Rejection takes the writer lock after its synchronous revocation callback has completed.
        while child.write(frame) { try Task.checkCancellation(); await Task.yield() }
        #expect(child.counters.writtenBytes == 0)
        try await releaseOutput(fake.directory.appendingPathComponent("release"))
        while !FileManager.default.fileExists(atPath: fake.directory.appendingPathComponent("emitted").path) {
            try Task.checkCancellation(); await Task.yield()
        }
        try #require(child.exitStatus == nil)
    }

    private func releaseOutput(_ fifo: URL) async throws {
        var descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        while descriptor < 0, errno == ENXIO {
            try Task.checkCancellation(); await Task.yield()
            descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        }
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0)
        let token = Data("1\n".utf8)
        let written: Int = token.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        try #require(written == token.count)
    }

    @Test func observedLeaderExitRefusesBufferedOutputWhileDescendantHoldsControl() async throws {
        let fake = try FakeRightyo("""
        (
          trap '' TERM
          exec 1>&-
          printf ready > descendant-ready
          exec /bin/sleep 60
        ) &
        while [ ! -f descendant-ready ]; do /bin/sleep 0.01; done
        printf 'authored-after-leader\\n'
        exit 0
        """)
        defer { fake.cleanUp() }
        let child = try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config,
            session: UUID().uuidString.lowercased(), provenance: .synthetic, coaching: .init())
        do {
            try #require(await eventually { child.exitStatus != nil && child.lines.base.queued.withLock { $0 > 0 } })
            #expect(try fake.recorded("descendant-ready") == "ready")
            #expect(child.coachingControl?.peerAvailable() == true)
            var iterator = child.lines.makeAsyncIterator()
            do { _ = try await iterator.next()
                Issue.record("Lost producer ownership still delivered stdout")
            } catch { #expect(error as? RightyoChildError == .transportLost) }
        } catch { _ = await child.stop(eofGrace: 0.05, termGrace: 0.05); throw error }
        _ = await child.stop(eofGrace: 0.05, termGrace: 0.05)
    }

    @Test func closingPartlyWrittenControlCannotGrantGracefulOutput() async throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1); _ = fcntl(ends[1], F_SETFL, O_NONBLOCK)
        _ = fcntl(ends[0], F_SETFL, O_NONBLOCK)
        let queue = DispatchQueue(label: "authored-partial-control")
        let release = DispatchSemaphore(value: 0), revocation = RightyoOutputRevocation()
        let writer = RightyoCoachingControlWriter(ends[1], revocation: revocation, queue: queue) {}
        defer { writer.close(); close(ends[0]); release.signal() }
        let fill = [UInt8](repeating: 88, count: 4_096)
        while fill.withUnsafeBytes({ Darwin.write(ends[1], $0.baseAddress, $0.count) }) > 0 {}
        var buffer = [UInt8](repeating: 0, count: 4_096)
        try #require(buffer.withUnsafeMutableBytes { read(ends[0], $0.baseAddress, $0.count) } == 4_096)
        #expect(writer.send(Data(repeating: 65, count: 8_000), validUntil: .now.advanced(by: .seconds(1))))
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            queue.async { ready.resume(); release.wait() } // After the first drain, before its blocked retry.
        }
        var observed = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(ends[0], $0.baseAddress, $0.count) }
            guard count > 0 else { break }; observed.append(contentsOf: buffer.prefix(count))
        }
        let partial = observed.filter { $0 == 65 }.count
        try #require(partial > 0 && partial < 8_001 && !observed.contains(10))
        writer.close(); revocation.ownedGroupEnded()
        let stream = AsyncThrowingStream<Data, any Error>.makeStream(), queued = RightyoByteCount()
        queued.withLock { $0 = 1 }; stream.continuation.yield(Data([7])); stream.continuation.finish()
        let output = RightyoChildOutput(base: .init(stream: stream.stream, queued: queued),
                                        revocation: revocation, control: writer)
        var iterator = output.makeAsyncIterator()
        do { _ = try await iterator.next()
            Issue.record("Truncated control granted graceful stdout")
        } catch { #expect(error as? RightyoChildError == .transportLost) }
    }
}
#endif
