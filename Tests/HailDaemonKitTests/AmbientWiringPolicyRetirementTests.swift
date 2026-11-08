#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #1050: a real scripted tmux pane stays tainted after policy is reallowed; refusing it keeps ambient listening.
/// The loopback child emits authored requests only. No real tmux, microphone, model or playback is used.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringPolicyRetirementTests {
    @Test func reallowedPolicyTaintRefusesTwoRequestsWithoutEndingAmbient() async throws {
        let rig = try await retiredPaste()
        let fake = try FakeRightyo(RightyoAmbientPendingInputTests.twoRequests)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        try RightyoAmbientPendingInputTests.release(fake, "go1")
        let log = AmbientEventDetails()
        let (listener, gate) = try listener(rig, fake: fake, log: log)
        do {
            let port = try await boundedAmbientListenerStart(listener)
            let pair = try await FallbackSocketPair.boundedConnect(
                port: port, selecting: [TmuxAuthorityRig.target], capabilities: ["probe", RequestRefusals.capability]
            )
            defer { pair.close() }
            let calls = rig.runner.calls.count
            let stream = UUID()
            try await recipientSocketSend(sessionFrame(target: TmuxAuthorityRig.target,
                payload: .audio(ambientSegment(stream: stream, sequence: 0))), on: pair.sockets[0])
            try await expectPending(on: pair.sockets[0], gate: gate, log: log, refusals: 1)
            rig.runner.setInput("") // Clearing text cannot lift the sticky taint.
            try RightyoAmbientPendingInputTests.release(fake, "go2")
            try await expectPending(on: pair.sockets[0], gate: gate, log: log, refusals: 2)
            #expect(rig.runner.pasted == ["synthetic input"] && rig.runner.enters == 0)
            #expect(!rig.runner.calls.dropFirst(calls).contains { $0.first == "capture-pane" })
            #expect(await listener.lastInput.latest(for: TmuxAuthorityRig.target) == nil)
            try await expectPolicyStop(rig, on: pair.sockets[0], stream: stream, gate: gate, log: log)
        } catch {
            await stop(listener)
            throw error
        }
        await stop(listener)
    }

    private func retiredPaste() async throws -> TmuxAuthorityRig {
        let rig = try await TmuxAuthorityRig.make(.paste)
        defer { rig.runner.gate.fire() }
        let sending = Task { try await rig.send() }
        try await rig.runner.gate.waitUntilSuspended()
        _ = try await rig.host.setTier(.locked, for: TmuxAuthorityRig.target)
        rig.runner.rebind()
        await #expect(throws: AdapterError.rebound("codex")) {
            try await rig.runner.gate.finish(sending)
        }
        rig.runner.restoreBinding()
        _ = try await rig.host.setTier(.open, for: TmuxAuthorityRig.target)
        #expect(rig.runner.pasted == ["synthetic input"] && rig.runner.enters == 0)
        return rig
    }

    private func listener(
        _ rig: TmuxAuthorityRig, fake: FakeRightyo, log: AmbientEventDetails
    ) throws -> (WebSocketListener, AmbientAudioGate) {
        let configuration = AmbientRightyoRouter.Configuration(
            executable: fake.executable, config: fake.config, target: TmuxAuthorityRig.target,
            binding: TmuxAuthorityRig.binding, allowSynthetic: true, timing: .init(eofGrace: 0.5, termGrace: 2)
        )
        let router = AmbientRightyoRouter(configuration: configuration, log: { log.record($0) })
        let gate = AmbientAudioGate(target: TmuxAuthorityRig.target, sink: GuardClockAmbientSink(router: router),
                                    sweepInterval: nil)
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer(ambientAudio: gate), hostName: "mac-test",
            singleTerminalReplyFallback: true, ambient: router
        )
        return (listener, gate)
    }

    private func expectPending(
        on socket: URLSessionWebSocketTask, gate: AmbientAudioGate, log: AmbientEventDetails, refusals: Int
    ) async throws {
        let frame = try await receiveFrame(on: socket, step: "policy-tainted input refusal")
        try #require(frame.payload == .control(.error(
            code: .voiceRouteRefused, message: "the target's input already holds unsent text"
        )))
        try await barrier(on: socket, step: "no terminal ambient refusal")
        #expect(await eventually { log.details("ambient_delivery_refused").count == refusals })
        #expect(log.details("ambient_delivery_refused").allSatisfy {
            $0 == "reason=inputPending shown=sent confirm=no_clips"
        })
        #expect(await gate.activeStream != nil)
        #expect(log.details("ambient_ended").isEmpty)
    }

    private func stop(_ listener: WebSocketListener) async {
        await bounded("policy-taint ambient cleanup") { await listener.stop(reason: "synthetic test complete") }
    }

    private func expectPolicyStop(
        _ rig: TmuxAuthorityRig, on socket: URLSessionWebSocketTask, stream: UUID,
        gate: AmbientAudioGate, log: AmbientEventDetails
    ) async throws {
        _ = try await rig.host.setTier(.locked, for: TmuxAuthorityRig.target)
        try await recipientSocketSend(sessionFrame(target: TmuxAuthorityRig.target,
            payload: .audio(ambientSegment(stream: stream, sequence: 1))), on: socket)
        #expect(try await ambientError(on: socket, step: "real policy denial still ends listening")
            == "ambient target_policy_changed")
        #expect(await gate.activeStream == nil)
        #expect(await eventually { !log.details("ambient_ended").isEmpty })
        #expect(log.details("ambient_delivery_refused").count == 2)
    }
}
#endif
