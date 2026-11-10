import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct VoiceGuardsOriginIsolationTests {
    @Test func publicSendCannotAcquireAmbientOriginEvenInsideAnAmbientTask() async throws {
        let adapter = FinalDeliveryAdapter(), route = try await VoiceGuardsRoute.make(adapter: adapter)
        let outcome = try await HostSession.$ambientInputDispatch.withValue(true) {
            try await route.host.send(VoiceGuardsRoute.words, to: route.target, from: "ambient-input")
        }
        guard case .needsConfirmation(let readBack) = outcome else {
            Issue.record("The public haild send path must retain guard escalation")
            return
        }
        #expect(readBack.guardHits == [VoiceGuardsRoute.rule.name])
        #expect(await adapter.deliveries.isEmpty)
        #expect(route.log.lines.isEmpty)
        let request = DeliveryRequest(target: route.target, binding: route.binding,
                                      lines: [VoiceGuardsRoute.words], device: "ambient-input")
        #expect(request.origin == .ordinary)
        await route.listener.stop()
    }

    @Test func localDispatchAndClientFieldsRemainOrdinary() async throws {
        let adapter = FinalDeliveryAdapter(), route = try await VoiceGuardsRoute.make(adapter: adapter)
        let connection = try #require(await route.listener.connectionID(of: route.peer))
        let local = LocalDispatchRequest(connection: connection, target: route.target,
                                         binding: route.binding, text: VoiceGuardsRoute.words)
        let localData = try JSONEncoder().encode(local)
        var localObject = try #require(JSONSerialization.jsonObject(with: localData) as? [String: Any])
        localObject["origin"] = "ambient"
        localObject["ambientInputDispatch"] = true
        let claimedLocal = try JSONDecoder().decode(LocalDispatchRequest.self,
            from: JSONSerialization.data(withJSONObject: localObject))
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) {
            try await route.listener.dispatch(claimedLocal)
        }
        // Unknown client fields and claimed provenance are never authority. Decode as a real incoming frame.
        let frame = sessionFrame(target: route.target, payload: .text(TextPayload(text: VoiceGuardsRoute.words)))
        let encoded = try JSONEncoder().encode(frame)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["origin"] = "ambient"
        object["ambientInputDispatch"] = true
        object["provenance"] = "voice"
        object["source"] = "ambient-input"
        var payload = try #require(object["payload"] as? [String: Any])
        payload["origin"] = "ambient"
        object["payload"] = payload
        let claimed = try JSONDecoder().decode(Frame.self, from: JSONSerialization.data(withJSONObject: object))
        let response = await route.session.receive(claimed)
        #expect(response.frames.contains {
            guard case .control(.error(.notAllowed, let message, _)) = $0.payload else { return false }
            return message == "target requires confirmation at the Mac"
        })
        #expect(await adapter.deliveries.isEmpty)
        #expect(route.log.lines.isEmpty)
        await route.listener.stop()
    }

    @Test func taskProgressWakeStillEscalatesMatchingText() async throws {
        let adapter = TaskProgressGuardedAdapter()
        let rig = try await TaskProgressGuardedWakeRig.make(adapter: adapter,
            policy: Policy(guardPatterns: [.init(name: "task rule", regex: ".")], voiceGuards: .off))
        defer { adapter.resume() }
        var deadlines = rig.clock.scheduled.stream.makeAsyncIterator()
        var finished = rig.finished.stream.makeAsyncIterator()
        _ = try await rig.start()
        _ = try #require(await deadlines.next())
        rig.clock.advance(by: .seconds(60))
        _ = try #require(await finished.next())
        #expect(await adapter.checks == 0)
        #expect(await adapter.accepted.isEmpty)
        #expect(await rig.listener.taskProgress(.init(action: .status)).task == nil)
        // A real guard read-back was retained, rather than a fabricated successful task handoff.
        let outcome = try await rig.host.send("synthetic progress text", to: rig.target)
        guard case .needsConfirmation(let readBack) = outcome else {
            Issue.record("Expected matching task policy to require confirmation")
            return
        }
        #expect(readBack.guardHits == ["task rule"])
        await rig.listener.stop()
    }
}
