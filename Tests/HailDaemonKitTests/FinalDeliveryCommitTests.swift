import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct FinalDeliveryCommitTests {
    @Test func ownerlessLocalCompletionRequiresTheOriginalPeer() async throws {
        let rig = try await FinalDeliveryRig.make(legacy: true)
        await rig.adapter.completion.arm()
        let delivery = Task { try await rig.ambient() }
        await rig.adapter.completion.wait()
        #expect(await rig.session.replyRequests.isEmpty)
        rig.peer.replyTransport.retire()
        await rig.adapter.completion.resume()
        await #expect(throws: LocalDispatchRefusal.connectionLost) { try await delivery.value }
        let ledger = await rig.listener.lastInput
        #expect(ledger.latest(for: FinalDeliveryRig.target) == nil)
        #expect(await rig.session.replyRequests.isEmpty)
        #expect(await rig.adapter.deliveries == ["synthetic input"])
        await rig.listener.stop()
    }

    @Test(arguments: [false, true])
    func phoneCompletionRequiresTheOriginalPeer(_ legacy: Bool) async throws {
        let rig = try await FinalDeliveryRig.make(legacy: legacy)
        let permit = try #require(rig.peer.replyTransport.issuePermit())
        await rig.adapter.completion.arm()
        let delivery = Task {
            await HostSession.$deliveryPeer.withValue(permit) { await rig.session.stageOrderPhoneInput() }
        }
        await rig.adapter.completion.wait()
        rig.peer.replyTransport.retire()
        await rig.adapter.completion.resume()
        #expect(await delivery.value == .unowned("reply authority changed"))
        let ledger = await rig.listener.lastInput
        #expect(ledger.latest(for: FinalDeliveryRig.target) == nil)
        #expect(await rig.session.replyRequests.isEmpty)
        #expect(await rig.adapter.deliveries == ["synthetic input"])
        await rig.listener.stop()
    }

    @Test(arguments: [false, true])
    func lastInputObserversRunAfterCommitGatesRelease(_ legacy: Bool) async throws {
        let rig = try await FinalDeliveryRig.make(legacy: legacy)
        let ledger = await rig.listener.lastInput
        let permit = try #require(rig.peer.replyTransport.issuePermit())
        let request = Mutex<HostReplyRequest?>(nil)
        let events = Mutex<[String]>([])
        let probe: @Sendable (String) -> Void = { event in
            let owner = request.withLock { $0 }
            let current = {
                permit.performIfCurrent { true } == true
            }
            let allowed = owner.map { $0.withAuthority(current) == true } ?? current()
            #expect(allowed)
            #expect(ledger.latest(for: FinalDeliveryRig.target) != nil)
            events.withLock { $0.append(event) }
        }
        await rig.session.attachLastInput(ledger, recordStoppedReply: { _ in probe("stopped") }, replyEvent: {
            probe($0.event)
        })
        let reply = UUID()
        await rig.session.seedStageOrderSegment(reply)
        await rig.adapter.completion.arm()
        let delivery = Task { try await rig.ambient() }
        await rig.adapter.completion.wait()
        let pending = await rig.session.replyRequests.values.first
        request.withLock { $0 = pending }
        #expect(events.withLock { $0.isEmpty })
        await rig.adapter.completion.resume()
        _ = try await delivery.value
        #expect(events.withLock { $0 } == ["stopped", "reply_backstop", "session_update_interaction"])
        #expect(await rig.session.segmentedReplies.isEmpty)
        #expect(await rig.session.stoppedReplies.contains(reply))
        await rig.listener.stop()
    }

    enum MissingPolicy: CaseIterable { case retained, held, handoff }

    @Test(arguments: MissingPolicy.allCases)
    func retainedDispatchRequiresAPolicyGeneration(_ source: MissingPolicy) async throws {
        let rig = try await FinalDeliveryRig.make(held: true)
        let id = try await rig.hold()
        let entry = try #require(await rig.host.heldRequests.entries[id])
        let send: @Sendable () async throws -> Void = {
            _ = try await rig.host.send("synthetic plain input", to: FinalDeliveryRig.target)
        }
        await #expect(throws: HostError.denied(.notAllowed(FinalDeliveryRig.target))) {
            switch source {
            case .retained:
                try await TaskProgressWakeScope.$retained.withValue(RetainedDeliveryStages(), operation: send)
            case .held:
                let scope = stageOrderHeldScope(entry, recorder: DeliveryStageRecorder())
                try await HeldSendScope.$current.withValue(scope, operation: send)
            case .handoff:
                try await TaskProgressWakeScope.$beforeHandoff.withValue({
                    Issue.record("missing policy refuses before handoff")
                }, operation: send)
            }
        }
        await rig.expectEmpty()
        await rig.listener.stop()
    }
}
