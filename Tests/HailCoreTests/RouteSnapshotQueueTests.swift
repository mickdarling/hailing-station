import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct RouteSnapshotQueueTests {
    private func legacyStore(
        _ host: HostEndpoint, socket: ScriptedSocket, gate: ObservedSleepGate
    ) async throws -> HostConnectionStore {
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: host.url)
        let store = HostConnectionStore(connector: connector, sleep: { try await gate.sleep($0) }, jitter: { 0 })
        try await socket.push(DeviceDiagnosticsSendingTests.hello(collecting: true))
        await store.upsert(host)
        await store.connect(host.id)
        await arrivalObserved { store.diagnosticsCollectingHost?.id == host.id }
        return store
    }

    @Test func legacyFlushSkipsSnapshotsBeforeTakingSendTokens() async throws {
        let rig = DeviceDiagnosticsTests()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        let log = rig.log()
        log.setEnabled(true)
        _ = log.nextBatch() // Remove the automatic app_info before constructing the exact FIFO.
        for _ in 0..<32 { log.record(.routeChange, [.phase: .token("configure")]) }
        for index in 0..<468 {
            rig.clock.advance(by: .seconds(1))
            log.record(.appForeground, timestamp: Int64(index))
        }
        #expect(log.bufferedCount == 500)
        let host = try endpoint(), gate = ObservedSleepGate(), socket = ScriptedSocket()
        let store = try await legacyStore(host, socket: socket, gate: gate)
        store.diagnostics = log
        await gate.waitForSleeper()
        await gate.fire()
        await gate.waitForSleeper() // The second flush is held until after the arrivals below.
        var sent = try await DeviceDiagnosticsSendingTests.diagnostics(socket)
        let expected = try (0..<501).map { try DiagnosticEvent(.appForeground, timestamp: Int64($0)) }
        #expect(sent == Array(expected.prefix(32)))
        for index in 468..<501 { log.record(.appForeground, timestamp: Int64(index)) }
        #expect(log.bufferedCount == 469)

        store.diagnostics = nil
        await gate.fire()
        await store.disconnect(host.id)
        while let batch = log.nextBatch() { sent += batch.events }
        #expect(sent == Array(expected.prefix(120)))
        rig.clock.advance(by: .seconds(60))
        #expect(sent + rig.drain(log) == expected)
    }

    @Test func capableReconnectSeesNewSnapshotsAndOriginalFieldsOnRetry() throws {
        let rig = DeviceDiagnosticsTests()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        let log = rig.log()
        log.setEnabled(true)
        _ = log.nextBatch()
        log.record(.routeChange, [.phase: .token("configure")], timestamp: 1)
        let change = try DiagnosticEvent(.routeChange, timestamp: 2, fields: [
            .phase: .token("change"), .route: .token("built_in_mic"), .routeSequence: .integer(2)
        ])
        log.record(change.name, change.fields, timestamp: change.timestamp)
        let legacy = try #require(log.nextBatch(for: [DiagnosticLimits.capability]))
        #expect(legacy.events == [change])
        log.requeue(legacy)
        let decision = try DiagnosticEvent(.routeChange, timestamp: 3, fields: [
            .decision: .token("no_hardware_episode"), .routeSequence: .integer(3)
        ])
        log.record(decision.name, decision.fields, timestamp: decision.timestamp)
        let capabilities = [DiagnosticLimits.capability, DiagnosticLimits.routeSnapshotCapability]
        let capable = try #require(log.nextBatch(for: capabilities))
        #expect(capable.events == [change, decision])
        #expect(!log.hasPending)
    }
}

/// A sleep gate whose test side can await the next sleeper without polling.
private actor ObservedSleepGate {
    private var waiter: CheckedContinuation<Void, any Error>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func sleep(_: Duration) async throws {
        try await withCheckedThrowingContinuation {
            waiter = $0
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }

    func waitForSleeper() async {
        guard waiter == nil else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func fire() {
        waiter?.resume()
        waiter = nil
    }
}
