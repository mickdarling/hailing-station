#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #913: "Nothing was sent." and the acknowledgement respect the connection's privacy reply hold. Each clip is paused
/// by a router test-only hook at the last point before its frames are sent: a not-sent clip once it has passed both
/// privacy checks (`notSentPlaying`), an acknowledgement just before it is sent (`acknowledgementHold`). Privacy is
/// then decided as an entry a child took decides it (`changeDuck`): the router's privacy state and the reply hold,
/// under the router's lock. No frame of the clip may reach the device, and the log says `suppressed_privacy`.
/// "Privacy on." queued with the decision plays next, and a decision for another connection holds nothing here.
/// Synthetic only. Named `AmbientWiring…` so it runs in the serial timing lane.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringNotSentHoldTests {
    static let shown = Array(AmbientWiringInputPendingTests.told.prefix(3))
    static let suppressed = "reason=inputPending shown=sent confirm=suppressed_privacy"
    static let privacyOn = AmbientAckClip(pcm: Data(repeating: 4, count: 480), sampleRate: 24_000,
                                          text: "Privacy on. I'm only listening for my name.")

    /// Privacy decided after the clip passed both checks, before its frames: none is sent.
    @Test func privacyDecidedAfterThePlayCheckSendsNoClipFrames() async throws {
        let gate = ClipGate()
        defer { gate.open() }
        let run = try await PendingInputRun.make(playing: gate.playing)
        defer { run.close() }
        let connection = try #require(await run.connection)
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        #expect(try await run.seen(3) == Self.shown)
        #expect(await eventually { gate.reached == 1 })
        await run.decidePrivate(connection)
        gate.open()
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [Self.suppressed] })
        try await barrier(on: run.socket, step: "no clip frames once privacy is decided")
        await run.finish()
    }

    /// The routed path (#636) shares `tellNotSent`: a route refusal's clip is held the same way.
    @Test func aRouteRefusalsClipIsNotSentOncePrivacyIsDecided() async throws {
        let gate = ClipGate()
        defer { gate.open() }
        let run = try await PendingInputRun.make(script: PendingInputRun.routeThenTarget,
                                                 fixture: "enrolled-formed-request.jsonl",
                                                 routes: try AmbientVoiceRouteRefusalTests.routes(),
                                                 playing: gate.playing)
        defer { run.close() }
        let connection = try #require(await run.connection)
        try await run.speak()
        #expect(try await run.seen(1) == [AmbientWiringNotSentLateTests.routeLine])
        #expect(await eventually { gate.reached == 1 })
        await run.decidePrivate(connection)
        gate.open()
        let suppressed = "reason=nothing_to_say shown=sent confirm=suppressed_privacy"
        #expect(await eventually { run.log.details("ambient_voice_route_refused") == [suppressed] })
        try await barrier(on: run.socket, step: "no route-refusal clip frames once privacy is decided")
        await run.finish()
    }

    /// "Privacy on.", queued on the chain with the decision as `switchDuck` queues it, is not held: it is the next
    /// thing the device receives, straight after the suppressed clip, and it is logged sent.
    @Test func privacyOnPlaysNextAndIsNotHeld() async throws {
        let gate = ClipGate()
        defer { gate.open() }
        let run = try await PendingInputRun.make(playing: gate.playing,
                                                 extra: [AmbientStopConfirmation.privacyOn: [Self.privacyOn]])
        defer { run.close() }
        let connection = try #require(await run.connection)
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        #expect(try await run.seen(3) == Self.shown)
        #expect(await eventually { gate.reached == 1 })
        let (router, listener) = (run.env.router, run.env.listener)
        await run.decidePrivate(connection) { state in
            AmbientRightyoRouter.clipChain(connection, in: &state).enqueue {
                await router.sayPrivacy(AmbientStopConfirmation.privacyOn, outcome: "on=true reason=device",
                                        connection: connection, listener: listener)
            }
        }
        gate.open()
        #expect(try await run.seen(2) == [.text(try #require(Self.privacyOn.text)), .audio])
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [Self.suppressed] })
        let said = "on=true reason=device confirm=\(AmbientStopConfirmation.privacyOn)/0:sent"
        #expect(await eventually { run.log.details("ambient_duck_confirmed") == [said] })
        try await barrier(on: run.socket, step: "nothing after privacy on")
        await run.finish()
    }

    /// The hold is per connection: privacy decided for another connection leaves this clip playing, as before.
    @Test func anotherConnectionsPrivacyHoldsNothingHere() async throws {
        let gate = ClipGate()
        defer { gate.open() }
        let run = try await PendingInputRun.make(playing: gate.playing)
        defer { run.close() }
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        #expect(try await run.seen(3) == Self.shown)
        #expect(await eventually { gate.reached == 1 })
        await run.decidePrivate(UUID())
        gate.open()
        #expect(try await run.seen(2) == Array(AmbientWiringInputPendingTests.told.suffix(2)))
        #expect(await eventually {
            run.log.details("ambient_delivery_refused") == [AmbientWiringInputPendingTests.logged]
        })
        await run.finish()
    }

    /// An acknowledgement whose clip would be sent once privacy is decided is not: no frame, `suppressed_privacy`.
    @Test func anAcknowledgementPastPrivacyIsNotSent() async throws {
        let gate = ClipGate()
        defer { gate.open() }
        let run = try await PendingInputRun.make(hold: gate.acknowledgement)
        defer { run.close() }
        let connection = try #require(await run.connection)
        try await run.speak()
        #expect(await eventually { gate.reached == 1 })
        await run.decidePrivate(connection)
        gate.open()
        #expect(await eventually {
            run.log.details("ambient_acknowledged").first?.hasSuffix(" outcome=suppressed_privacy") == true
        })
        try await barrier(on: run.socket, step: "no acknowledgement once privacy is decided")
        await run.finish()
    }
}

/// Pauses a clip at the router's test-only hook until the test opens it, and counts the clips that got there.
final class ClipGate: Sendable {
    private let latch = MeetingLatch()
    private let count = Mutex(0)
    var reached: Int { count.withLock { $0 } }
    var playing: NotSentPlaying { NotSentPlaying { [self] _ in await pause() } }
    var acknowledgement: AcknowledgementHold { AcknowledgementHold { [self] in await pause() } }
    func open() { latch.open() }

    private func pause() async {
        count.withLock { $0 += 1 }
        await latch.wait()
    }
}

extension PendingInputRun {
    /// Decides privacy for `connection` as an entry a child took does (`changeDuck`): the router's privacy state and
    /// the listener's reply hold, set together under the router's lock. `also` runs under that same lock, as
    /// `switchDuck` queues "Privacy on." with the decision.
    func decidePrivate(_ connection: UUID,
                       also: (inout AmbientRightyoRouter.State) -> Void = { _ in }) async {
        let hold = await env.listener.replyHold
        env.router.state.withLock { state in
            state.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil)
            hold.set(true, connection: connection)
            also(&state)
        }
    }
}
#endif
