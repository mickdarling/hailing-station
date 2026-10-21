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
            // The same stream's next segment: the gate ends it and tells the device why (#636), and only now does the
            // child, at EOF, dispatch what it heard.
            try await send(ambientSegment(stream: stream, sequence: 1, isFinal: true), on: pair)
            #expect(try await recipientSocketReceive(on: pair.sockets[0]).payload == Self.reselected)
            try await pair.barrier()
            await router.settle()
            #expect(await rig.adapter.deliveries.isEmpty)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    static let reselected = FramePayload.control(.error(code: .notAllowed, message: AmbientAudioGate.reselectedMessage))

    private func send(_ segment: AudioPayload, on pair: FallbackSocketPair) async throws {
        try await recipientSocketSend(sessionFrame(target: LegacyReferenceRig.target, payload: .audio(segment)),
                                      on: pair.sockets[0])
    }

    /// When the owner selects away and back around a reload (#405); `twoReloads` reloads twice and never reselects.
    enum Reselection: CaseIterable { case none, beforeReload, afterReload, twoReloads }

    /// A reload swaps the stream's child mid-stream: the new child keeps the selection the stream opened on, and so
    /// does the child of a second reload. It dispatches while that selection holds, and nothing once the owner has
    /// selected away and back, before the reload or after it.
    @Test(arguments: Reselection.allCases)
    func aReloadedChildKeepsTheSelectionItsStreamOpenedOn(_ reselection: Reselection) async throws {
        let fake = try FakeRightyo("/bin/cat > v1-audio.bin")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 2, termGrace: 2))
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        do {
            let stream = UUID()
            try await reloadSend(ambientSegment(stream: stream, sequence: 0), on: pair)
            try await pair.barrier()
            // The old child is running its own behaviour before the new install is written.
            #expect(await eventually { fakeFileSize(fake, "v1-audio.bin") == 3_200 })
            if reselection == .twoReloads {
                // A middle child that only listens, so neither replaced child dispatches.
                try rewriteFake(fake, "/bin/cat > v2-audio.bin")
                #expect(await env.router.reload() == .reloaded)
                #expect(await eventually { fakeFileSize(fake, "v2-audio.bin") >= 0 })
            }
            try rewriteFake(fake, ambientEchoAtEOF)
            if reselection == .beforeReload { try await awayAndBack(pair) }
            #expect(await env.router.reload() == .reloaded)
            if reselection == .afterReload { try await awayAndBack(pair) }
            try await reloadSend(ambientSegment(stream: stream, sequence: 1, isFinal: true), on: pair)
            let delivers = reselection == .none || reselection == .twoReloads
            if !delivers {
                #expect(try await recipientSocketReceive(on: pair.sockets[0]).payload == Self.reselected)
            }
            try await pair.barrier()
            await settle(env.router, step: "reloaded run")
            #expect(await env.rig.adapter.contexts.count == (delivers ? 1 : 0))
        } catch {
            await env.listener.stop(reason: "synthetic test failed")
            throw error
        }
        await env.listener.stop(reason: "synthetic test complete")
    }

    private func awayAndBack(_ pair: FallbackSocketPair) async throws {
        try await pair.select("recipient:other", on: 0)
        try await pair.select(RecipientTestRig.target, on: 0)
    }

    private func reloadSend(_ segment: AudioPayload, on pair: FallbackSocketPair) async throws {
        try await recipientSocketSend(sessionFrame(target: RecipientTestRig.target, payload: .audio(segment)),
                                      on: pair.sockets[0])
    }
}
#endif
