#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct RightyoCoachingGracefulRaceTests {
    @Test func peerLossBeforeLocalEOFCannotBecomeGraceful() async throws {
        var control: [Int32] = [-1, -1]
        try #require(pipe(&control) == 0)
        let queue = DispatchQueue(label: "authored-coaching-probe-order")
        queue.suspend()
        defer { queue.resume() }
        let revocation = RightyoOutputRevocation()
        let writer = RightyoCoachingControlWriter(control[1], revocation: revocation, queue: queue) {}
        defer { writer.close() }
        close(control[0]) // Peer loss precedes local EOF, with the idle watcher deliberately withheld.
        writer.close()
        revocation.ownedGroupEnded()
        let stream = AsyncThrowingStream<Data, any Error>.makeStream(), queued = RightyoByteCount()
        let stale = Data("authored-stale-output".utf8)
        queued.withLock { $0 += stale.count }; stream.continuation.yield(stale)
        stream.continuation.finish()
        let output = RightyoChildOutput(base: .init(stream: stream.stream, queued: queued),
                                        revocation: revocation, control: writer)
        var iterator = output.makeAsyncIterator()
        do { _ = try await iterator.next()
            Issue.record("Peer loss was converted to graceful buffered output")
        } catch { #expect(error as? RightyoChildError == .transportLost) }
    }
}
#endif
