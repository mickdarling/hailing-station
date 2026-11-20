#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Loopback device frames and synthetic children/adapters only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringDialogNoticeTests {
    @Test(arguments: WebSocketListenerDialogNoticeTests.rows, WebSocketListenerDialogNoticeTests.causes)
    func everyNoticeUsesTheSpokenNameAndOnlyUntouchedRequestsPlayTheClip(
        // swiftlint:disable:next large_tuple
        row: (DialogBlock.Effects, Int, String), cause: DialogBlock.Cause
    ) async throws {
        let (effects, earlier, _) = row
        let block = DialogBlock(cause: cause, effects: effects)
        let run = try await PendingInputRun.make(routes: routes())
        defer { run.close() }
        let error: any Error = earlier == 0 ? AdapterError.blockedByDialog(block)
            : HostError.partial(delivered: Array(repeating: "synthetic earlier words", count: earlier),
                                reason: .dialog(block))
        await run.adapter.failHandoff(with: error)
        try await run.speak()
        let notice = DialogDeliveryNotice(block: block, earlierDelivered: earlier)
        let told = AmbientWiringInputPendingTests.acknowledged
            + [.control(.error(code: .voiceRouteRefused, message: notice.message(target: "Scratch")))]
        #expect(try await run.seen(3) == told)
        let shouldPlayClip = effects == .none && earlier == 0
        if shouldPlayClip {
            #expect(try await run.seen(2) == [.text("Nothing was sent."), .audio])
        }
        #expect(await eventually { !run.log.details("ambient_delivery_refused").isEmpty })
        let confirm = shouldPlayClip ? "confirmnotsent/0:sent" : "suppressed_effects"
        #expect(run.log.details("ambient_delivery_refused") == ["reason=blockedByDialog shown=sent confirm=\(confirm)"])
        let connection = try #require(await run.connection)
        #expect(run.queued.count(for: connection) == (shouldPlayClip ? 1 : 0))
        #expect(await run.env.gate.activeStream != nil)
        #expect(await run.lastInput == nil)
        await run.adapter.passHandoff()
        try run.release("go2")
        #expect(try await run.seen(2) == AmbientWiringInputPendingTests.acknowledged)
        #expect(await eventually { await run.adapter.contexts.count == 2 })
        let contexts = await run.adapter.contexts
        #expect(await !run.armed(contexts[0].id))
        #expect(await eventually { await run.armed(contexts[1].id) })
        try await barrier(on: run.socket, step: "no contradictory clip or terminal error")
        #expect(run.log.details("ambient_ended").isEmpty)
        await run.finish()
    }

    @Test func ownDialogKeepsTheRequestTurnAndTheAcknowledgementSnapshot() async throws {
        let latch = MeetingLatch()
        defer { latch.open() }
        let run = try await PendingInputRun.make(options: .init(capabilities: HeardTurnRig.capabilities),
                                                 routes: routes(), hold: AcknowledgementHold { await latch.wait() })
        defer { run.close() }
        let block = DialogBlock(cause: .uninspectable, effects: .enterMayHaveExecuted)
        await run.adapter.failHandoff(with: AdapterError.blockedByDialog(block))
        try await run.speak()
        let first = try await heard(run)
        #expect(await eventually { await run.adapter.contexts.count == 1 })
        await run.adapter.passHandoff()
        try run.release("go2")
        let second = try await heard(run)
        #expect(first != second)
        #expect(await eventually { await run.adapter.contexts.count == 2 })
        try await barrier(on: run.socket, step: "refusal waits for captured acknowledgement")
        latch.open()
        let frames = try await run.seen(5)
        let controls = frames.compactMap { frame -> ControlPayload? in
            if case .control(let control) = frame { return control }
            return nil
        }
        let expectedMessage = "Couldn't check Scratch for a dialog. "
            + "Your words may have gone through; check the Mac before resending."
        #expect(controls == [.error(code: .voiceRouteRefused,
                                    message: expectedMessage, turn: first)])
        #expect(Array(frames.prefix(2)) == AmbientWiringInputPendingTests.acknowledged)
        #expect(await eventually { !run.log.details("ambient_delivery_refused").isEmpty })
        let connection = try #require(await run.connection)
        #expect(await run.env.listener.heardTurnCount(connection) == 0)
        #expect(run.queued.count(for: connection) == 0)
        #expect(run.log.details("ambient_voice_route_refused").isEmpty)
        #expect(run.log.details("ambient_ended").isEmpty)
        let contexts = await run.adapter.contexts
        #expect(contexts[0].binding.targetID == RecipientTestRig.target)
        #expect(contexts[1].binding.targetID == RecipientTestRig.target)
        try await barrier(on: run.socket, step: "no clip after possible Enter")
        await run.finish()
    }

    @Test func untouchedDialogStillRespectsPrivacy() async throws {
        let run = try await PendingInputRun.make(routes: routes())
        defer { run.close() }
        let block = DialogBlock(cause: .uninspectable, effects: .none)
        await run.adapter.failHandoff(with: AdapterError.blockedByDialog(block))
        await run.adapter.holdHandoff()
        try await run.speak()
        await run.adapter.waitForHandoff()
        let connection = try #require(await run.connection)
        run.env.router.state.withLock { $0.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil) }
        await run.adapter.releaseHandoff()
        _ = try await run.seen(3)
        #expect(await eventually {
            run.log.details("ambient_delivery_refused")
                == ["reason=blockedByDialog shown=sent confirm=suppressed_privacy"]
        })
        try await barrier(on: run.socket, step: "no not-sent clip while private")
        await run.finish()
    }

    @Test func dialogCompletionKeepsTheOriginalRequestUUID() async throws {
        let fake = try FakeRightyo(AmbientWiringAcknowledgementTests.fixtureWithNames)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let shown = Mutex<[UUID]>([])
        let finished = Mutex<[UUID]>([])
        let refusal = LocalDispatchRefusal.blockedByDialog(
            .init(cause: .uninspectable, effects: .pasteMayHaveExecuted), earlierDelivered: 2
        )
        var settings = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 0.5, termGrace: 2)
        )
        settings.heardRequests = AmbientHeardRequests(show: { request, _ in
            shown.withLock { $0.append(request) }
        }, finish: { request, actual in
            #expect(actual == refusal)
            if let request { finished.withLock { $0.append(request) } }
        })
        let pipeline = try RightyoAmbientPipeline(configuration: settings,
                                                  dispatcher: DialogNoticeRefusingDispatcher(refusal: refusal))
        pipeline.finishInput()
        _ = try await pipeline.run()
        #expect(shown.withLock { $0.count } == 1)
        #expect(finished.withLock { $0 } == shown.withLock { $0 })
    }

    private func routes() throws -> VoiceRoutes {
        try VoiceRoutes(defaultTarget: RecipientTestRig.target, routes: [
            .init(target: RecipientTestRig.target, name: "Scratch"), .init(target: "recipient:other", name: "Deck")
        ])
    }

    private func heard(_ run: PendingInputRun) async throws -> UUID {
        var frame = try await receiveFrame(on: run.socket, step: "dialog heard turn")
        if case .control(.ambientOverheard) = frame.payload {
            frame = try await receiveFrame(on: run.socket, step: "heard turn after fixture discussion")
        }
        guard case .control(.ambientHeard(_, _, let turn)) = frame.payload else {
            Issue.record("Expected heard turn, received \(frame.payload)")
            throw TestSupportError.expectedOneControl
        }
        return try #require(turn)
    }
}
private struct DialogNoticeRefusingDispatcher: RightyoAmbientDispatching {
    let refusal: LocalDispatchRefusal
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? { throw refusal }
}
#endif
