#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Natural dismissal (rightyo#98) through the ambient pipeline and wiring: an admitted `dismiss` is reported as a
/// content-free diagnostic and the stream keeps listening.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringDismissTests {
    /// Emits RightyO's dismissal fixture under the given session except its `stopped`, reads stdin to EOF, then
    /// emits `stopped`, as `rightyo listen --mode stdin` does. Argument 7 is the session id.
    static let fixtureUntilEOF = """
        /usr/bin/sed -e '$d' -e "s/dismissal-demo/$7/g" events.jsonl
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/dismissal-demo/$7/g"
        """

    @Test func theFixtureDismissalReachesTheObserverAndTheRunEndsCleanly() async throws {
        let fake = try FakeRightyo(Self.fixtureUntilEOF)
        defer { fake.cleanUp() }
        try fake.install(fixture: "dismissal-events.jsonl")
        let receipts = Mutex<[RightyoDismissReceipt]>([])
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: .init(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            onDismiss: { receipt in receipts.withLock { $0.append(receipt) } }
        ), dispatcher: dispatcher)
        pipeline.finishInput()
        let summary = try await pipeline.run()
        #expect(summary.delivered == 1)
        #expect(await dispatcher.requests.count == 1)
        #expect(receipts.withLock { $0 } == [RightyoDismissReceipt(
            reason: "stop-phrase", scope: ["playback", "pending_request"], withdrawn: 0, alreadyDelivered: 1)])
        #expect(await pipeline.withdrawnDropped == 0)
    }

    @Test func ambientKeepsListeningAfterADismissal() async throws {
        let fake = try FakeRightyo(Self.fixtureUntilEOF)
        defer { fake.cleanUp() }
        try fake.install(fixture: "dismissal-events.jsonl")
        let events = AmbientEventNames()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), events: events)
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        try await pair.barrier()
        #expect(await eventually { events.all.contains("ambient_dismissed") })
        // The dismissal ended nothing: the run is live, the stream still takes audio, and no error reached the peer.
        #expect(!events.all.contains("ambient_ended"))
        #expect(env.router.liveRuns == 1)
        #expect(await env.rig.adapter.contexts.count == 1)
        try await recipientSocketSend(audio(stream, 1, final: true), on: pair.sockets[0])
        try await pair.barrier()
        await env.router.settle()
        #expect(events.all.filter { $0 == "ambient_ended" }.count == 1)
        #expect(events.all.firstIndex(of: "ambient_dismissed").map { $0 < events.all.count - 1 } == true)
        await env.listener.stop(reason: "synthetic test complete")
    }
}
#endif
