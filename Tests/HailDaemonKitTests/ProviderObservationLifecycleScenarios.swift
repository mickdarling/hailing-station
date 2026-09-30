import Foundation
import Testing
@testable import HailDaemonKit

func observedEarlyFailure(completed: Int) async throws {
    let rig = try await ObservedRig.make()
    await rig.adapter.configure(failureAfter: completed)
    await rig.adapter.setEmission([.accepted])
    await rig.adapter.setEmitBeforeFailure()
    try await rig.host.withObservedSession(target: ObservedRig.target,
                                                 configuration: rig.configuration()) { session in
        do {
            _ = try await session.submit("invented first\ninvented second", utteranceID: UUID())
            Issue.record("failed dispatch unexpectedly registered sent")
        } catch {
            if completed == 0 {
                #expect(error as? ProviderCoordinatorSyntheticError == .arbitraryFailure)
            } else {
                let expected = HostError.partial(delivered: ["invented first"], reason: "adapter delivery failed")
                #expect(error as? HostError == expected)
            }
        }
        var records: [ProviderObservedEvent] = []
        for _ in 0...completed { records.append(try #require(try await session.next())) }
        #expect(records.map(\.event.sequence) == Array(0...completed))
        #expect(records.allSatisfy { $0.correlation == .unassociated(.unknownTurn) })
        let proposed = try #require(records.first?.event.turn)
        #expect(await session.state(for: proposed.id) == nil)
        #expect(await rig.adapter.delivered.count == completed)
    }
    #expect(rig.adapter.cancellations.count == 1)
}

func observedEarlyOverflow(bytes: Bool) async throws {
    let rig = try await ObservedRig.make()
    await rig.adapter.configure(holdDispatch: true)
    let emission: [ProviderEventKind] = bytes
        ? [.text("éé", isFinal: true, visibility: .userVisible)] : [.accepted, .finished]
    await rig.adapter.setEmission(emission)
    var config = rig.configuration()
    config.maxQueuedEvents = 1
    if bytes { config.maxQueuedTextBytes = 3 }
    try await rig.host.withObservedSession(target: ObservedRig.target,
                                                 configuration: config) { session in
        let input = Task { try await session.submit("invented input", utteranceID: UUID()) }
        await rig.adapter.dispatch.arrivals.wait()
        await rig.adapter.cancellations.wait()
        #expect(await session.status == .lost(.bufferOverflow))
        #expect(rig.adapter.cancellations.count == 1)
        await rig.adapter.dispatch.release()
        let sent = try rig.sent(try await input.value)
        if !bytes { #expect(try await session.next()?.correlation == .associated(sent, state: .accepted)) }
        await #expect(throws: ProviderObservationLoss.bufferOverflow) { try await session.next() }
        #expect(await session.state(for: sent.id) == (bytes ? .sent : .accepted))
    }
    #expect(rig.adapter.cancellations.count == 1)
}

func observedEndedPrefix(held: Bool, failed: Bool) async throws {
    let rig = try await ObservedRig.make()
    await rig.adapter.configure(holdDispatch: held)
    try await rig.host.withObservedSession(target: ObservedRig.target,
                                                 configuration: rig.configuration()) { session in
        let input = Task { try await session.submit("invented input", utteranceID: UUID()) }
        if held { await rig.adapter.dispatch.arrivals.wait() } else { _ = try await input.value }
        await rig.adapter.finish(failed ? ProviderObservationError.unavailable : nil)
        await rig.adapter.cancellations.wait()
        #expect(await session.status == .lost(failed ? .streamFailed : .streamEnded))
        if held { await rig.adapter.dispatch.release() }
        let sent = try rig.sent(try await input.value)
        var records: [ProviderObservedEvent] = []
        for _ in 0..<3 { records.append(try #require(try await session.next())) }
        #expect(records.map(\.event.sequence) == [0, 1, 2])
        #expect(records.map(\.event.turn) == [sent, sent, sent])
        #expect(Set(records.map(\.event.id)).count == 3)
        #expect(records.map(\.event.kind) == [.accepted,
            .text("invented provider output", isFinal: true, visibility: .userVisible), .finished])
        #expect(records.map(\.correlation) == [.associated(sent, state: .accepted),
                                              .associated(sent, state: .accepted), .associated(sent, state: .finished)])
        #expect(await session.state(for: sent.id) == .finished)
        await #expect(throws: failed ? ProviderObservationLoss.streamFailed : .streamEnded) { try await session.next() }
    }
    #expect(rig.adapter.cancellations.count == 1)
}

func observedReturnedScope() async throws {
    let rig = try await ObservedRig.make()
    await rig.adapter.configure(holdDispatch: true)
    await rig.adapter.setEmission([])
    let completed = ObservedCounter()
    let scope = Task {
        let result = try await rig.host.withObservedSession(target: ObservedRig.target,
                                                           configuration: rig.configuration()) { session in
            let input = Task { try await session.submit("invented first", utteranceID: UUID()) }
            await rig.adapter.dispatch.arrivals.wait()
            let proposed = try #require(await rig.adapter.delivered.first)
            return (input, proposed, session)
        }
        completed.increment()
        return result
    }
    await rig.adapter.cancellations.wait()
    #expect(completed.count < 1)
    #expect(await rig.adapter.delivered.count == 1)
    await rig.adapter.dispatch.release()
    let (input, proposed, session) = try await scope.value
    #expect(completed.count == 1)
    #expect(try rig.sent(try await input.value) == proposed)
    #expect(await session.state(for: proposed.id) == .sent)
    #expect(rig.adapter.cancellations.count == 1)
}

func observedStoppedWrite(lines: Int) async throws {
    let rig = try await ObservedRig.make()
    await rig.adapter.configure(holdDispatch: true)
    await rig.adapter.setEmission([])
    try await rig.host.withObservedSession(target: ObservedRig.target,
                                                 configuration: rig.configuration()) { session in
        let text = lines == 1 ? "invented first" : "invented first\ninvented second"
        let input = Task { try await session.submit(text, utteranceID: UUID()) }
        await rig.adapter.dispatch.arrivals.wait()
        let proposed = try #require(await rig.adapter.delivered.first)
        await session.stop()
        #expect(rig.adapter.cancellations.count == 1)
        #expect(await session.status == .stopped)
        #expect(await session.state(for: proposed.id) == nil)
        await rig.adapter.dispatch.release()
        if lines == 1 {
            #expect(try rig.sent(try await input.value) == proposed)
            #expect(await session.state(for: proposed.id) == .sent)
        } else {
            await #expect(throws: HostError.partial(delivered: ["invented first"], reason: "delivery cancelled")) {
                try await input.value
            }
            #expect(await session.state(for: proposed.id) == nil)
        }
        #expect(await rig.adapter.delivered.count == 1)
        #expect(try await session.next() == nil)
    }
    #expect(rig.adapter.cancellations.count == 1)
}
