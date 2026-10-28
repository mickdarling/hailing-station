import Foundation
import Testing
@testable import HailCore

/// #850: scripted transport and hand-stepped waits, with no elapsed-time assertion.
@MainActor
@Suite(.serialized) struct AmbientReconnectBackoffTests {
    @Test func doublesToNamedCapAndClampsInjectedJitter() {
        let pacing = AmbientReconnectPacing()
        let delays = (0..<10).map { _ in pacing.delay(jitterUnit: 0.5) }
        #expect(delays == [1.5, 3, 6, 12, 24, 48, 60, 60, 60, 60])
        #expect(delays.last == AmbientReconnectPacing.maximumDelay)
        for unit in [-1.0, 0, 0.5, 1, 2] {
            pacing.reset()
            let delay = pacing.delay(jitterUnit: unit)
            #expect(delay >= 1.2 - 0.000_001 && delay <= 1.8 + 0.000_001)
            #expect(abs(delay - 1.5 * (0.8 + 0.4 * min(max(unit, 0), 1))) < 0.000_001)
            for _ in 0..<10 {
                #expect(pacing.delay(jitterUnit: unit) <= AmbientReconnectPacing.maximumDelay)
            }
        }
    }

    @Test func manyFailuresHaveOnePacingOwnerAndKeepReconnectingVisible() async throws {
        let steps = AmbientRetrySteps()
        let rig = try AmbientReconnectRig(retrySleep: { try await steps.sleep($0) })
        let clock = TestInstantClock()
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        await rig.socket.fail()
        for index in 0..<24 {
            try await waitUntil { await steps.started == index + 1 }
            #expect(await steps.pending == 1)
            #expect(await rig.connector.openCount(for: rig.endpoint.url) == index + 1)
            #expect(await steps.completed == index)
            #expect(rig.controller.reconnect.status == "Reconnecting…")
            #expect(rig.controller.isOn && rig.controller.isListening && rig.released == 0)
            #expect(rig.appPresentation.card(hostName: nil) != nil)
            for _ in 0..<8 {
                rig.controller.reconnect.restore(store: rig.store)
                await rig.controller.update(binding: nil, scene: .active)
            }
            #expect(await rig.connector.openCount(for: rig.endpoint.url) == index + 1)
            clock.advance(by: .seconds(60))
            await steps.release(index)
        }
        try await waitUntil { await steps.started == 25 }
        #expect(rig.notices.isEmpty && rig.capture.startCount == 1)
        #expect(await steps.durations.prefix(8) == [1.5, 3, 6, 12, 24, 48, 60, 60].map { .seconds($0) })
        await rig.close()
        await steps.releaseAll()
    }

    @Test(arguments: [0.0, 0.5, 1.0])
    func transportWaitUsesInjectedJitter(_ unit: Double) async throws {
        let steps = AmbientRetrySteps()
        let rig = try AmbientReconnectRig(retrySleep: { try await steps.sleep($0) }, jitter: { unit })
        try await rig.start()
        await rig.socket.fail()
        try await waitUntil { await steps.started == 1 }
        let milliseconds = Int64((1_500 * (0.8 + 0.4 * unit)).rounded())
        #expect(await steps.durations == [.milliseconds(milliseconds)])
        await rig.close()
        await steps.releaseAll()
    }

    @Test(arguments: ["path", "foreground"])
    func resetReplacesWaitAndObsoleteCompletionCannotOpenASocket(_ trigger: String) async throws {
        let steps = AmbientRetrySteps()
        let rig = try AmbientReconnectRig(retrySleep: { try await steps.sleep($0) })
        try await rig.start()
        await rig.socket.fail()
        for index in 0..<3 {
            try await waitUntil { await steps.started == index + 1 }
            await steps.release(index)
        }
        try await waitUntil { await steps.started == 4 }
        let opens = await rig.connector.openCount(for: rig.endpoint.url)
        if trigger == "path" { await rig.store.networkPathChanged() } else { await rig.store.sceneBecameActive() }
        try await waitUntil { await steps.started == 5 }
        #expect(await steps.durations.last == .seconds(1.5))
        #expect(await rig.connector.openCount(for: rig.endpoint.url) == opens)
        await steps.release(3) // This sleeper deliberately ignores cancellation and returns successfully.
        await settle()
        #expect(await rig.connector.openCount(for: rig.endpoint.url) == opens)
        await steps.release(4)
        try await waitUntil { await steps.started == 6 }
        #expect(await rig.connector.openCount(for: rig.endpoint.url) == opens + 1)
        #expect(await steps.durations.last == .seconds(3))
        await rig.close()
        await steps.releaseAll()
    }

    @Test(arguments: [false, true])
    func ownerVetoDuringWaitIsPromptAndCannotSpendAnotherAttempt(privacy: Bool) async throws {
        let steps = AmbientRetrySteps()
        let rig = try AmbientReconnectRig(retrySleep: { try await steps.sleep($0) })
        try await rig.start()
        await rig.socket.fail()
        try await waitUntil { await steps.started == 1 }
        if privacy { try? await rig.store.setPrivacy(on: true, host: rig.endpoint.id) } else {
            await rig.controller.turnOff()
        }
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(await steps.pending == 1) // Off completed even though the sleeper has not cooperated.
        #expect(rig.controller.reconnect.status == nil)
        await steps.release(0)
        await settle()
        #expect(await rig.connector.openCount(for: rig.endpoint.url) == 1)
        #expect(await steps.started == 1)
        #expect(rig.notices.last?.reason == (privacy ? .privacy : .ownerStop))
        await rig.close()
    }
}

/// Intentionally cancellation-uncooperative: generation and intent checks must reject obsolete completions.
actor AmbientRetrySteps {
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var durations: [Duration] = []
    private(set) var completed = 0
    var started: Int { durations.count }
    var pending: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        let index = durations.count
        durations.append(duration)
        await withCheckedContinuation { waiters[index] = $0 }
        completed += 1
    }

    func release(_ index: Int) { waiters.removeValue(forKey: index)?.resume() }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter.resume() }
    }
}
