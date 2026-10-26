#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringDeliveryRefusalTests {
    @Test func aDeviceWithoutAmbientHeardStillGetsTheRefusalAndClipWithoutATurn() async throws {
        let capabilities = ["probe", RequestRefusals.capability, HeardTurns.capability]
        let run = try await PendingInputRun.make(options: .init(capabilities: capabilities))
        defer { run.close() }
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        #expect(try await run.seen(AmbientWiringInputPendingTests.told.count) == AmbientWiringInputPendingTests.told)
        #expect(await eventually {
            run.log.details("ambient_delivery_refused") == [AmbientWiringInputPendingTests.logged]
        })
        let connection = try #require(await run.connection)
        #expect(await run.env.listener.heardTurnCount(connection) == 0)
        try await barrier(on: run.socket, step: "no heard frame or duplicate refusal")
        await run.finish()
    }

    /// A missing turn is rejected by producer validation today. Exercise the relay boundary directly, through the
    /// router's real callbacks, so a future pre-delivery refusal or absent text cannot silence its line or clip.
    @Test(arguments: [false, true])
    func noHeardTextStillGetsTheRefusalAndClipWithoutATurn(_ delivered: Bool) async throws {
        let run = try await PendingInputRun.make(options: .init(capabilities: HeardTurnRig.capabilities))
        defer { run.close() }
        let connection = try #require(await run.connection)
        let callbacks = run.env.router.heardRequests(on: connection, listener: run.env.listener,
                                                     notices: AmbientRefusalNotices())
        let relay = AmbientHeardRelay(onHeard: nil, requests: callbacks)
        relay.observe(try RightyoInputConsumerTests().event("request", sequence: 2))
        if delivered { await relay.deliver() }
        await relay.finish(refusal: .inputPending)
        await relay.finish()
        #expect(try await run.seen(3) == Array(AmbientWiringInputPendingTests.told.dropFirst(2)))
        #expect(await eventually {
            run.log.details("ambient_delivery_refused") == [AmbientWiringInputPendingTests.logged]
        })
        #expect(await run.env.listener.heardTurnCount(connection) == 0)
        try await barrier(on: run.socket, step: "no heard text, turn, or duplicate refusal")
        await run.finish()
    }

    @Test(arguments: [false, true])
    func completionAndNewRequestObservationCannotLeakAKey(_ finishedFirst: Bool) async throws {
        let shown = Mutex<[UUID]>([])
        let completed = Mutex<[UUID?]>([])
        let relay = AmbientHeardRelay(onHeard: nil, requests: AmbientHeardRequests(show: { request, _ in
            shown.withLock { $0.append(request) }
        }, finish: { request, _ in
            completed.withLock { $0.append(request) }
        }))
        relay.observe(try RightyoInputConsumerTests().request())
        await relay.deliver()
        let first = try #require(shown.withLock { $0.first })
        if finishedFirst {
            await relay.finish()
            await relay.finish(refusal: .inputPending)
        }
        relay.observe(try RightyoInputConsumerTests().request(sequence: 3))
        await relay.finish(refusal: .inputPending)
        await relay.finish()
        #expect(completed.withLock { $0 } == (finishedFirst ? [first, nil, nil] : [nil]))
    }
}
#endif
