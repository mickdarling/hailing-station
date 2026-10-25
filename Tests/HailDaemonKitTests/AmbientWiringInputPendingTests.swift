#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #894: an ambient request refused because the target's input already holds unsent text ends its run logged as
/// `ambient_ended dispatch inputPending`, not the generic `dispatch deliveryRefused`, which every other refusal keeps.
/// Only the name changes: the run still ends and the phone is still told (keeping the stream is later work).
/// Synthetic child and adapter only; not device hearing. Named `AmbientWiring…` so it runs in the serial timing lane.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringInputPendingTests {
    /// One ambient request whose handoff fails with `error`: the `ambient_ended` details and what the phone was told.
    private func refusedRun(_ error: any Error) async throws -> (ended: [String], told: String) {
        let fake = try FakeRightyo("/usr/bin/sed \"s/tool-demo/$7/g\" events.jsonl\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let ended = Mutex<[String]>([])
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 2), onEvent: { event in
            if event.event == "ambient_ended" { ended.withLock { $0.append(event.detail ?? "") } }
        })
        await env.rig.adapter.failHandoff(with: error)
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        let told = try await ambientError(on: pair.sockets[0], step: "refused dispatch")
        #expect(await eventually { !ended.withLock { $0 }.isEmpty })
        #expect(await env.gate.activeStream == nil, "the stream still ends, as before")
        await env.listener.stop(reason: "synthetic test complete")
        return (ended.withLock { $0 }, told)
    }

    @Test func pendingInputEndsTheRunUnderItsOwnName() async throws {
        let run = try await refusedRun(AdapterError.inputPending(reason: .staleInput))
        #expect(run.ended == ["dispatch inputPending"])
        #expect(run.told == "ambient stopped: dispatch inputPending")
    }

    @Test func aRebindRefusalStillEndsItAsDeliveryRefused() async throws {
        let run = try await refusedRun(AdapterError.rebound("reply"))
        #expect(run.ended == ["dispatch deliveryRefused"])
        #expect(run.told == "ambient stopped: dispatch deliveryRefused")
    }
}
#endif
