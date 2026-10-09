#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #230 end to end through the listener: phone audio reaches a fake `rightyo`, its admitted request is typed into a
/// legacy (`tmux`-kind) target with a reply reference in its block, and a reply naming that reference reaches only
/// the streaming device while a second device selects the same target. Synthetic only; not device hearing.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringReplyReferenceTests {
    @Test func theStreamingDeviceHearsTheReplyWhileASecondDeviceSelectsTheTarget() async throws {
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
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [LegacyReferenceRig.target, LegacyReferenceRig.target]
        )
        defer { pair.close() }
        do {
            try await exercise(listener: listener, router: router, rig: rig, pair: pair)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func exercise(
        listener: WebSocketListener, router: AmbientRightyoRouter, rig: LegacyReferenceRig, pair: FallbackSocketPair
    ) async throws {
        let stream = UUID()
        for sequence in 0..<3 {
            let segment = ambientSegment(stream: stream, sequence: sequence, isFinal: sequence == 2)
            try await recipientSocketSend(sessionFrame(target: LegacyReferenceRig.target, payload: .audio(segment)),
                                          on: pair.sockets[0])
        }
        try await pair.barrier()
        await router.settle()
        let deliveries = await rig.adapter.deliveries
        try #require(deliveries.count == 1)
        #expect(deliveries[0].binding == "binding")
        let reference = try #require(blockReference(in: deliveries[0].text))
        #expect(deliveries[0].text.hasSuffix(
            RightyoInputEvent.replyBlock(target: LegacyReferenceRig.target, request: reference)
        ))
        // What `haild reply tmux:reply --request <ref> --say …` publishes: text, then streamed speech.
        let reply = referenceDescriptor(reference, audio: true)
        for frame in [recipientText(reply), recipientAudio(reply, sequence: 0, final: true)] {
            #expect(try await listener.publish(frame) == 1)
            #expect(try await recipientSocketReceive(on: pair.sockets[0]) == frame)
        }
        try await pair.barrier()
        // Without the reference the reply is as ambiguous as before #230 and reaches neither device.
        await #expect(throws: LocalReplyRefusal.notUniqueRecipient) {
            try await listener.publish(recipientText(referenceDescriptor(nil)))
        }
        try await pair.barrier()
    }
}
#endif
