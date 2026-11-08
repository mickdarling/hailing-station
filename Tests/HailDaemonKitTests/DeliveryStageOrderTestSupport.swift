import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

final class DeliveryStageRecorder: Sendable {
    private struct State {
        var events: [String] = []
        var peerHeld = false
    }
    private let state = Mutex(State())
    var events: [String] { state.withLock { $0.events } }

    func router() -> Bool {
        state.withLock {
            #expect(!$0.peerHeld)
            $0.events.append("router")
        }
        return true
    }

    func instrument(_ stages: RetainedDeliveryStages) -> RetainedDeliveryStages {
        var stages = stages
        for stage in DeliveryAdmission.Stage.allCases {
            guard let gate = stages.gates[stage] else { continue }
            stages.gates[stage] = DeliveryAdmission.Gate(validate: gate.validate, perform: { operation in
                self.state.withLock {
                    $0.events.append(String(describing: stage))
                    if stage == .peerLifecycle { $0.peerHeld = true }
                }
                defer {
                    if stage == .peerLifecycle { self.state.withLock { $0.peerHeld = false } }
                }
                try gate.perform(operation)
            })
        }
        return stages
    }

    func expectRouterBeforePeer() throws {
        let events = events
        let router = try #require(events.firstIndex(of: "router"))
        let peer = try #require(events.firstIndex(of: "peerLifecycle"))
        #expect(router < peer)
    }
}

func stageOrderHeldScope(
    _ entry: HeldRequestEntry, recorder: DeliveryStageRecorder,
    policyCurrent: @escaping @Sendable () -> Bool = { true },
    selected: @escaping @Sendable () -> Bool = { true },
    noticeCurrent: @escaping @Sendable () -> Bool = { true }
) -> HeldSendScope {
    HeldSendScope(entry: entry, renewOnly: false, allowed: { recorder.router() }, selected: selected,
                  noticeCurrent: noticeCurrent, policyCurrent: policyCurrent)
}

extension HostSession {
    func stageOrderAuthority(peer: ReplyTransportPermit, owner: HostReplyOwnership?) -> RetainedDeliveryStages {
        Self.$deliveryPeer.withValue(peer) {
            finalDeliveryAuthority(owner: owner, target: FinalDeliveryRig.target)
        }
    }

    func stageOrderPhoneInput() async -> HostDeliveryOutcome {
        let frame = sessionFrame(target: FinalDeliveryRig.target, payload: .text(TextPayload(text: "synthetic input")))
        guard let input = await authorize(frame, device: "synthetic-device") else {
            Issue.record("input requires authorization")
            return .refused(.notAllowed, "input requires authorization")
        }
        return await deliver(input, recordsLastInput: true)
    }

    func seedStageOrderSegment(_ reply: UUID) {
        peerCapabilities.insert(ReplySegments.capability)
        repliesInFlight.append(reply)
        segmentedReplies.insert(reply)
    }
}
