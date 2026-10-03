#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// Stdin expiry and eviction against stalled children (#203).
extension RightyoChildProcessTests {
    /// The chunk already taken while the pipe was full ages like a queued one: once the child resumes after
    /// `backlogAge`, nothing taken before the stall is written.
    @Test func aChunkWaitingOnAFullPipeExpiresLikeTheQueue() async throws {
        let fake = try FakeRightyo("echo ready\n/bin/sleep 3\n/usr/bin/wc -c | /usr/bin/tr -d ' ' > stdin-bytes.txt")
        defer { fake.cleanUp() }
        let child = try fake.child(.init(eofGrace: 20, termGrace: 20, backlogAge: 0.5))
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        let chunks = 60, size = 3_200
        for _ in 0..<chunks { #expect(child.write(Data(repeating: 9, count: size))) }
        try await Task.sleep(for: .milliseconds(1_500))
        let stalled = child.counters.writtenBytes
        #expect(await child.stop() == .exited(0))
        let counters = child.counters
        #expect(counters.writtenBytes == stalled)
        #expect(counters.writtenBytes + counters.droppedBytes == chunks * size)
        #expect(try fake.recorded("stdin-bytes.txt") == "\(stalled)\n")
    }

    /// A million two-byte chunks against a stalled child with a 1 MiB backlog (up to 524,288 queued chunks):
    /// eviction stays O(1), so the caller is never held up (O(n) removal takes minutes here), and
    /// every byte is either written (then read once the child resumes) or counted as dropped.
    @Test func manyTinyChunksEvictInConstantTime() async throws {
        let fake = try FakeRightyo("echo ready\n/bin/sleep 2\n/usr/bin/wc -c | /usr/bin/tr -d ' ' > stdin-bytes.txt")
        defer { fake.cleanUp() }
        let child = try fake.child(.init(eofGrace: 20, termGrace: 20, backlogBytes: 1_048_576, backlogAge: 60))
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        let chunks = 1_000_000, started = ContinuousClock.now
        var accepted = 0
        for _ in 0..<chunks where child.write(Data([1, 0])) { accepted += 1 }
        #expect(accepted == chunks)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await child.stop() == .exited(0))
        let counters = child.counters
        #expect(counters.droppedChunks > 0)
        #expect(counters.writtenBytes + counters.droppedBytes == chunks * 2)
        #expect(try fake.recorded("stdin-bytes.txt") == "\(counters.writtenBytes)\n")
    }
}
#endif
