import Foundation
import Testing
@testable import HailDaemonKit

func observedTimeoutAndVisibility() async throws {
    let rig = try await ObservedRig.make()
    await rig.adapter.setEmission([.accepted])
    var config = rig.configuration()
    config.input = .init(timeout: .seconds(1), deliveryMode: .contextual)
    try await rig.host.withObservedSession(target: ObservedRig.target,
                                                 configuration: config) { session in
        let old = try rig.sent(try await session.submit("invented first", utteranceID: UUID()))
        #expect(try await session.next()?.correlation == .associated(old, state: .accepted))
        let internalText = ProviderEventKind.text("invented internal marker", isFinal: true, visibility: .internalOnly)
        try await rig.adapter.emit(internalText, turn: old)
        let internalRecord = try #require(try await session.next())
        #expect(internalRecord.event.kind == internalText)
        #expect(internalRecord.correlation == .associated(old, state: .accepted))
        try await rig.adapter.emit(.running)
        #expect(try await session.next()?.correlation == .unassociated(.noTurn))
        #expect(await session.state(for: old.id) == .accepted)
        await rig.clock.poll.sleeps.wait()
        await rig.clock.advance(.seconds(2))
        await rig.clock.poll.sleeps.wait(for: 2) // The first monitor tick expired deadlines before sleeping again.
        #expect(await session.state(for: old.id) == .timedOut)
        let current = try rig.sent(try await session.submit("invented second", utteranceID: UUID()))
        #expect(try await session.next()?.correlation == .associated(current, state: .accepted))
        try await rig.adapter.emit(.finished, turn: old)
        #expect(try await session.next()?.correlation == .unassociated(.timedOut))
        #expect(await session.state(for: old.id) == .timedOut)
        #expect(await session.state(for: current.id) == .accepted)
    }
    #expect(rig.adapter.cancellations.count == 1)
}

func observedTerminalTail(capacity: Bool) async throws {
    let rig = try await ObservedRig.make()
    await rig.adapter.configure(holdDispatch: true)
    await rig.adapter.setEmission([.accepted])
    var config = rig.configuration()
    if capacity { config.input = .init(maxEvents: 1, deliveryMode: .contextual) }
    try await rig.host.withObservedSession(target: ObservedRig.target, configuration: config) { session in
        let input = Task { try await session.submit("invented input", utteranceID: UUID()) }
        await rig.adapter.dispatch.arrivals.wait()
        let proposed = try #require(await rig.adapter.delivered.first)
        try await rig.adapter.emit(.finished, turn: proposed, sequenceOverride: capacity ? nil : 2)
        try await rig.adapter.emit(.running, turn: proposed)
        await rig.adapter.listings.wait(for: 7) // Startup twice, submit twice, three retained events.
        await rig.adapter.dispatch.release()
        let sent = try rig.sent(try await input.value)
        #expect(try await session.next()?.correlation == .associated(sent, state: .accepted))
        let reason: ProviderObservationLoss = capacity ? .capacityExceeded : .orderingGap
        await #expect(throws: reason) { try await session.next() }
        #expect(await session.status == .lost(reason))
        #expect(await session.state(for: sent.id) == .accepted)
    }
    #expect(rig.adapter.cancellations.count == 1)
}

func observedDuplicateAndGap() async throws {
    let rig = try await ObservedRig.make()
    await rig.adapter.setEmission([.accepted])
    try await rig.host.withObservedSession(target: ObservedRig.target,
                                                 configuration: rig.configuration()) { session in
        let sent = try rig.sent(try await session.submit("invented input", utteranceID: UUID()))
        let first = try #require(try await session.next())
        #expect(first.correlation == .associated(sent, state: .accepted))
        await rig.adapter.replayLast()
        #expect(try await session.next()?.correlation == .rejected(.duplicateEvent))
        try await rig.adapter.emit(.running, turn: sent)
        #expect(try await session.next()?.correlation == .associated(sent, state: .running))
        try await rig.adapter.emit(.finished, turn: sent, sequenceOverride: 4)
        await #expect(throws: ProviderObservationLoss.orderingGap) { try await session.next() }
        #expect(await session.status == .lost(.orderingGap))
        #expect(await session.state(for: sent.id) == .running)
    }
    #expect(rig.adapter.cancellations.count == 1)
}

func observedCapacity(turns: Bool) async throws {
    let rig = try await ObservedRig.make()
    await rig.adapter.setEmission(turns ? [] : [.accepted])
    var config = rig.configuration()
    config.input = .init(maxTurns: turns ? 1 : 128, maxEvents: turns ? 128 : 1, deliveryMode: .contextual)
    try await rig.host.withObservedSession(target: ObservedRig.target,
                                                 configuration: config) { session in
        let sent = try rig.sent(try await session.submit("invented first", utteranceID: UUID()))
        if turns {
            await #expect(throws: ProviderContractError.capacityExceeded) {
                try await session.submit("invented second", utteranceID: UUID())
            }
            #expect(await rig.adapter.delivered.count == 1)
            #expect(await session.state(for: sent.id) == .sent)
        } else {
            #expect(try await session.next()?.correlation == .associated(sent, state: .accepted))
            try await rig.adapter.emit(.finished, turn: sent)
            await #expect(throws: ProviderObservationLoss.capacityExceeded) { try await session.next() }
            #expect(await session.state(for: sent.id) == .accepted)
        }
        #expect(await session.status == .lost(.capacityExceeded))
    }
    #expect(rig.adapter.cancellations.count == 1)
}
