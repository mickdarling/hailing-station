#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #636 end to end through the listener (second-key review on #691): the owner selects away and back while a stream
/// is open, then the stream ends and its fake `rightyo` dispatches what it heard. The router built that child's
/// delivery step on the selection the stream opened on, so nothing is typed. Synthetic only; not device hearing.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringStreamSelectionTests {
    @Test func whatAStreamHeardBeforeTheOwnerSelectedAwayAndBackIsNotTyped() async throws {
        let fake = try FakeRightyo(ambientEchoAtEOF)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let rig = try await LegacyReferenceRig.make()
        let router = AmbientRightyoRouter(configuration: .init(
            executable: fake.executable, config: fake.config, target: LegacyReferenceRig.target, binding: "binding",
            allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        ))
        let gate = AmbientAudioGate(target: LegacyReferenceRig.target, sink: router, sweepInterval: nil)
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer(ambientAudio: gate), hostName: "mac-test",
            singleTerminalReplyFallback: true, ambient: router
        )
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(port: port, selecting: [LegacyReferenceRig.target])
        defer { pair.close() }
        do {
            let stream = UUID()
            try await send(ambientSegment(stream: stream, sequence: 0), on: pair)
            try await pair.select(LegacyReferenceRig.other, on: 0)
            try await pair.select(LegacyReferenceRig.target, on: 0)
            // The same stream continues on the same target and ends; only now does the child dispatch.
            try await send(ambientSegment(stream: stream, sequence: 1, isFinal: true), on: pair)
            try await pair.barrier()
            await router.settle()
            #expect(await rig.adapter.deliveries.isEmpty)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func send(_ segment: AudioPayload, on pair: FallbackSocketPair) async throws {
        try await recipientSocketSend(sessionFrame(target: LegacyReferenceRig.target, payload: .audio(segment)),
                                      on: pair.sockets[0])
    }
}
#endif
