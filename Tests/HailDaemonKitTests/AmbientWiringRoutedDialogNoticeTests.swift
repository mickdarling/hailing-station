#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension AmbientWiringDialogNoticeTests {
    /// A routed refusal has no heard bubble or acknowledgement, as before; its turn stays nil.
    @Test func routedDialogKeepsItsSpokenNameWithoutInventingAHeardTurn() async throws {
        let script = PendingInputRun.routeThenTarget.replacingOccurrences(of: "Deck.", with: "Deck, add a slide.")
        let routes = try VoiceRoutes(defaultTarget: RecipientTestRig.target, routes: [
            .init(target: RecipientTestRig.target, name: "Scratch"), .init(target: "recipient:other", name: "Deck")
        ])
        let run = try await PendingInputRun.make(options: .init(capabilities: HeardTurnRig.capabilities),
                                                 script: script, fixture: "enrolled-formed-request.jsonl",
                                                 routes: routes)
        defer { run.close() }
        let block = DialogBlock(cause: .uninspectable, effects: .enterMayHaveExecuted)
        await run.adapter.failHandoff(with: AdapterError.blockedByDialog(block))
        try await run.speak()
        var frame = try await receiveFrame(on: run.socket, step: "routed dialog refusal")
        if case .control(.ambientOverheard) = frame.payload {
            frame = try await receiveFrame(on: run.socket, step: "refusal after fixture discussion")
        }
        let message = "Couldn't check Deck for a dialog. "
            + "Your words may have gone through; check the Mac before resending."
        #expect(frame.payload == .control(.error(code: .voiceRouteRefused, message: message, turn: nil)))
        #expect(await eventually { !run.log.details("ambient_delivery_refused").isEmpty })
        #expect(run.log.details("ambient_acknowledged").isEmpty)
        let connection = try #require(await run.connection)
        #expect(await run.env.listener.heardTurnCount(connection) == 0)
        #expect(run.queued.count(for: connection) == 0)
        try await barrier(on: run.socket, step: "no fabricated routed heard turn or clip")
        await run.adapter.passHandoff()
        try run.release("go2")
        let heard = try await receiveFrame(on: run.socket, step: "next own request heard")
        guard case .control(.ambientHeard(_, _, let turn)) = heard.payload else {
            await run.finish()
            throw TestSupportError.expectedOneControl
        }
        #expect(turn != nil)
        #expect(try await run.seen(2) == AmbientWiringInputPendingTests.acknowledged)
        #expect(await eventually { await run.adapter.contexts.count == 2 })
        let contexts = await run.adapter.contexts
        #expect(contexts[0].binding.targetID == "recipient:other")
        #expect(contexts[1].binding.targetID == RecipientTestRig.target)
        #expect(run.log.details("ambient_voice_route_refused").isEmpty)
        #expect(run.log.details("ambient_ended").isEmpty)
        await run.finish()
    }
}
#endif
