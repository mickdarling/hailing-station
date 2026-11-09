#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct RightyoStdinGapTests {
    @Test func drainedFillRestoresMainEvictionAndRealPCMCounters() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        defer { Darwin.close(descriptors[0]) }
        let worker = DispatchQueue(label: "synthetic.stdin.gap")
        let writer = RightyoStdinWriter(input: descriptors[1], exit: RightyoExitLatch(),
                                       timing: .init(backlogBytes: 6_400, backlogAge: 60), writer: worker)
        let pcm = Data(repeating: 7, count: 3_200)
        #expect(writer.write(pcm, leadingSilenceBytes: 3_200))
        worker.sync {} // The prefix and first PCM have left the queue and the pipe accepted both.
        #expect(writer.counters.writtenBytes == 3_200)
        worker.suspend()
        for _ in 0..<3 { #expect(writer.write(pcm)) }
        #expect(writer.counters.droppedChunks == 1)
        #expect(writer.counters.droppedBytes == 3_200) // Main's 6,400-byte backlog, no retained reserve.
        writer.close(abandon: false)
        worker.resume()
        worker.sync {}
        let bytes = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: false).readDataToEndOfFile()
        #expect(bytes == Data(repeating: 0, count: 3_200) + pcm + pcm + pcm)
        #expect(writer.counters.writtenBytes == 9_600) // Synthetic silence is excluded.
        #expect(writer.counters.writtenBytes + writer.counters.droppedBytes == 4 * pcm.count)
    }

    @Test func evictedPrefixDoesNotCountAsDroppedRealAudio() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        defer { Darwin.close(descriptors[0]) }
        let worker = DispatchQueue(label: "synthetic.stdin.eviction")
        worker.suspend()
        let writer = RightyoStdinWriter(input: descriptors[1], exit: RightyoExitLatch(),
                                       timing: .init(backlogBytes: 3_200, backlogAge: 60), writer: worker)
        let pcm = Data(repeating: 9, count: 3_200)
        #expect(writer.write(pcm, leadingSilenceBytes: 3_200))
        #expect(writer.write(pcm)) // Evicts prefixed item, then returns to the PCM-only bound.
        #expect(writer.counters.droppedChunks == 1 && writer.counters.droppedBytes == 3_200)
        writer.close(abandon: false)
        worker.resume()
        worker.sync {}
        let bytes = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: false).readDataToEndOfFile()
        #expect(bytes == pcm)
        #expect(writer.counters.writtenBytes == 3_200)
    }
}
#endif
