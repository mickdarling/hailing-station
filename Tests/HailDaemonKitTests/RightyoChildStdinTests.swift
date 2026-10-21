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
    /// eviction stays O(1), so the caller is never held up, and every byte is either written (then read once the
    /// child resumes) or counted as dropped. The child stays stalled until the test releases it, so the backlog
    /// overflows however slowly a loaded runner writes; O(1) is checked by comparing the cost per chunk while
    /// evicting against the cost while filling, not by a wall-clock bound. O(n) removal would make the evicting
    /// slice thousands of times slower (minutes here); a factor of 10 leaves room for scheduler noise.
    @Test func manyTinyChunksEvictInConstantTime() async throws {
        let fake = try FakeRightyo("echo ready\nuntil [ -f go ]; do /bin/sleep 0.05; done\n"
            + "/usr/bin/wc -c | /usr/bin/tr -d ' ' > stdin-bytes.txt")
        defer { fake.cleanUp() }
        let child = try fake.child(.init(eofGrace: 20, termGrace: 20, backlogBytes: 1_048_576, backlogAge: 60))
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        let chunks = 1_000_000, slice = 200_000
        var accepted = 0, filling = Duration.zero, evicting = Duration.zero
        for index in 0..<chunks {
            let started = ContinuousClock.now
            if child.write(Data([1, 0])) { accepted += 1 }
            if index < slice { filling += ContinuousClock.now - started }
            if index >= chunks - slice { evicting += ContinuousClock.now - started }
        }
        try Data().write(to: fake.directory.appendingPathComponent("go"))
        #expect(accepted == chunks)
        #expect(evicting < filling * 10, "evicting \(evicting) vs filling \(filling) for \(slice) chunks each")
        #expect(await child.stop() == .exited(0))
        let counters = child.counters
        #expect(counters.droppedChunks > 0)
        #expect(counters.writtenBytes + counters.droppedBytes == chunks * 2)
        #expect(try fake.recorded("stdin-bytes.txt") == "\(counters.writtenBytes)\n")
    }

    /// Taken and evicted chunks are released at once: after any number of large-chunk evictions the storage
    /// references only the live chunks, so the 64 KB backlog bound holds for memory too.
    @Test func evictedChunksAreReleasedImmediately() {
        var queue = RightyoChunkQueue()
        let size = 65_536
        for step in 0..<3_000 {
            queue.append((Data(repeating: UInt8(step % 251), count: size), UInt64(step)))
            if step >= 1 { _ = queue.removeFirst() } // One live chunk, as at the 64 KB bound with 64 KB chunks.
            #expect(queue.storedBytes <= size)
        }
        #expect(queue.first?.at == 2_999)
        _ = queue.removeFirst()
        #expect(queue.isEmpty && queue.storedBytes == 0)
        // Mixed: a window of 16 small live chunks never retains more than the window.
        for step in 0..<5_000 {
            queue.append((Data(repeating: 1, count: 4_096), UInt64(step)))
            if step >= 16 { _ = queue.removeFirst() }
            #expect(queue.storedBytes <= 17 * 4_096)
        }
    }
}
#endif
