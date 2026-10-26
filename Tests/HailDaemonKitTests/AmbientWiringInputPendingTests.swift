#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #894: an ambient request refused because the target's input already holds unsent text no longer ends the run
/// (ask 3). The device that said it gets tap-to-talk's fixed refusal line and hears "Nothing was sent.", the log has
/// the refusal's name and outcomes only, and the stream goes on to deliver the next request once the input is clear.
/// Every other refusal still ends the run, as `dispatch deliveryRefused`. Synthetic child and adapter only; not
/// device hearing. Named `AmbientWiring…` so it runs in the serial timing lane.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringInputPendingTests {
    static let line = "the target's input already holds unsent text"
    static let acknowledged: [PendingInputSeen] = [.text("On it."), .audio]
    /// The request's acknowledgement first, then the line, then "Nothing was sent." (review P3-1).
    static let told = acknowledged + [.control(.error(code: .voiceRouteRefused, message: line)),
                                      .text("Nothing was sent."), .audio]
    static let logged = "reason=inputPending shown=sent confirm=confirmnotsent/0:sent"

    @Test(arguments: [PendingInputReason.staleInput, .appeared, .tainted])
    func pendingInputIsToldAndTheStreamDeliversTheNextRequest(_ reason: PendingInputReason) async throws {
        let run = try await PendingInputRun.make()
        defer { run.close() }
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: reason))
        try await run.speak()
        #expect(try await run.seen(Self.told.count) == Self.told)
        #expect(await eventually { !run.log.details("ambient_delivery_refused").isEmpty })
        #expect(run.log.details("ambient_delivery_refused") == [Self.logged])
        #expect(await run.env.gate.activeStream != nil, "the stream goes on")
        #expect(await run.lastInput == nil, "a refused request records no last-input device")
        // The input was cleared meanwhile: the same child's next request is typed, and acknowledged.
        await run.adapter.passHandoff()
        try run.release("go2")
        #expect(await eventually { await run.adapter.contexts.count == 2 })
        #expect(try await run.seen(2) == Self.acknowledged)
        // The synthetic adapter records a handoff before failing it; only the typed one armed a reply recipient.
        let contexts = await run.adapter.contexts
        #expect(await eventually { await run.armed(contexts[1].id) })
        #expect(await !run.armed(contexts[0].id))
        #expect(await eventually { await run.lastInput != nil })
        #expect(await run.lastInput?.connection == run.connection)
        // Nothing more reached the device: no `ambient stopped` error, no second line or clip.
        try await barrier(on: run.socket, step: "no ambient error after the refusal")
        #expect(run.log.details("ambient_ended").isEmpty)
        #expect(run.log.details("ambient_delivery_refused").count == 1)
        await run.finish()
        // Tokens only: never the heard words, the line's text or the target.
        #expect(run.log.allDetails.allSatisfy { !$0.contains("discussion") && !$0.contains("Rightyo") })
        #expect(run.log.details("ambient_delivery_refused").allSatisfy {
            !$0.contains("unsent") && !$0.contains(RecipientTestRig.target)
        })
    }

    /// Meeting mode (#735) adds no gate on host clips, as for the acknowledgement and a route refusal's clip: the
    /// refusal is told as in any other mode. Privacy holds every request before dispatch, so it is never refused
    /// (`RightyoInputConsumerTests.whilePrivateARequestIsHeldBackSoPendingInputRefusesNothing`).
    @Test func inMeetingModeTheRefusalIsStillTold() async throws {
        let run = try await PendingInputRun.make(holdFirst: true)
        defer { run.close() }
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        #expect(await eventually { await run.env.gate.activeStream != nil })
        let connection = try #require(await run.connection)
        run.env.router.setMeeting(on: true, connection: connection, reason: "voice")
        #expect(run.env.router.meetingMode(connection: connection))
        try run.release("go1")
        #expect(try await run.seen(Self.told.count) == Self.told)
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [Self.logged] })
        #expect(run.log.details("ambient_ended").isEmpty)
        await run.finish()
    }

    /// Privacy always wins (Jarvis on #909): privacy taken while the adapter waited shows the line but never says
    /// "Nothing was sent.". The test sets the router's privacy state directly, as an entry a child took would.
    @Test func privacyTakenDuringTheWaitShowsTheLineButPlaysNoClip() async throws {
        let run = try await PendingInputRun.make()
        defer { run.close() }
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        await run.adapter.holdHandoff()
        try await run.speak()
        await run.adapter.waitForHandoff()
        let connection = try #require(await run.connection)
        run.env.router.state.withLock { $0.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil) }
        await run.adapter.releaseHandoff()
        #expect(try await run.seen(3) == Array(Self.told.prefix(3)))
        #expect(await eventually {
            run.log.details("ambient_delivery_refused") == ["reason=inputPending shown=sent confirm=suppressed_privacy"]
        })
        try await barrier(on: run.socket, step: "no clip while private")
        await run.finish()
    }

    /// Review P3-1: the refusal's line and clip wait for that request's acknowledgement, however late it is sent. The
    /// acknowledgement is held (the router's test-only hold); nothing of the refusal may reach the device meanwhile.
    @Test func theRefusalWaitsForItsAcknowledgement() async throws {
        let latch = MeetingLatch()
        defer { latch.open() }
        let run = try await PendingInputRun.make(hold: { await latch.wait() })
        defer { run.close() }
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        #expect(await eventually { await run.adapter.contexts.count == 1 })
        try await Task.sleep(for: .milliseconds(500))
        try await barrier(on: run.socket, step: "nothing of the refusal before its acknowledgement")
        #expect(run.log.details("ambient_delivery_refused").isEmpty)
        latch.open()
        #expect(try await run.seen(Self.told.count) == Self.told)
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [Self.logged] })
        await run.finish()
    }

    /// Review P3-2: a voice-route refusal (#636) and then a pending-input refusal on one child are told in the order
    /// said. The first is held after its line, behind a piece the test queues on the connection's privacy clip chain;
    /// the second's line may not reach the device until the first's clip has been sent.
    @Test func aRouteRefusalThenAPendingInputRefusalAreToldInTheOrderSaid() async throws {
        let run = try await PendingInputRun.make(script: PendingInputRun.routeThenTarget,
                                                 fixture: "enrolled-formed-request.jsonl",
                                                 routes: try AmbientVoiceRouteRefusalTests.routes())
        defer { run.close() }
        let latch = MeetingLatch()
        defer { latch.open() }
        let connection = try #require(await run.connection)
        run.env.router.state.withLock {
            AmbientRightyoRouter.clipChain(connection, in: &$0).enqueue { await latch.wait() }
        }
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        let routeLine = PendingInputSeen.control(.error(code: .voiceRouteRefused,
                                                        message: "voice route: nothing to send to Deck"))
        #expect(try await run.seen(1) == [routeLine])
        try run.release("go2")
        #expect(try await run.seen(2) == Self.acknowledged, "the second request's acknowledgement")
        #expect(await eventually { await run.adapter.contexts.count == 1 })
        try await Task.sleep(for: .milliseconds(500))
        try await barrier(on: run.socket, step: "the second refusal waits for the first")
        latch.open()
        #expect(try await run.seen(5) == [.text("Nothing was sent."), .audio] + Array(Self.told.dropFirst(2)))
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [Self.logged] })
        #expect(run.log.details("ambient_voice_route_refused")
                == ["reason=nothing_to_say shown=sent confirm=confirmnotsent/0:sent"])
        await run.finish()
    }

    @Test func aRebindRefusalStillEndsItAsDeliveryRefused() async throws {
        let fake = try FakeRightyo("/usr/bin/sed \"s/tool-demo/$7/g\" events.jsonl\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let log = AmbientEventDetails()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 2), onEvent: { log.record($0) })
        await env.rig.adapter.failHandoff(with: AdapterError.rebound("reply"))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        let told = try await ambientError(on: pair.sockets[0], step: "refused dispatch")
        #expect(await eventually { !log.details("ambient_ended").isEmpty })
        #expect(await env.gate.activeStream == nil, "the stream still ends, as before")
        await env.listener.stop(reason: "synthetic test complete")
        #expect(log.details("ambient_ended") == ["dispatch deliveryRefused"])
        #expect(told == "ambient stopped: dispatch deliveryRefused")
        #expect(log.details("ambient_delivery_refused").isEmpty)
    }
}
#endif
