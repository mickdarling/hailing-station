import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Sending device diagnostics (#234): only to a host that advertises `device_diagnostics`, buffered while
/// offline and flushed on reconnect; ambient start, stop causes and host refusals are recorded.
@MainActor
@Suite struct DeviceDiagnosticsSendingTests {
    let suite = "hail-device-diagnostics-send-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    func enabledLog() -> DeviceDiagnostics {
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [.app: .token("t")], wallNow: { 5 })
        log.setEnabled(true)
        return log
    }

    static func hello(collecting: Bool) -> ControlPayload {
        .hello(HelloInfo(versions: [ProtocolVersion.current],
                         capabilities: ["ping"] + (collecting ? [DiagnosticLimits.capability] : []), deviceName: "Mac"))
    }

    static func diagnostics(_ socket: ScriptedSocket) async throws -> [DiagnosticEvent] {
        try await socket.sentFrames().flatMap { frame -> [DiagnosticEvent] in
            guard case .control(.diagnostic(let events)) = frame.payload else { return [] }
            return events
        }
    }

    @Test func bufferedWhileOfflineAndFlushedWhenACollectingHostIsReady() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = try endpoint()
        let first = ScriptedSocket(), second = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(first), for: host.url)
        await connector.enqueue(.socket(second), for: host.url)
        let store = HostConnectionStore(connector: connector, sleep: { _ in }, jitter: { 0 })
        let log = enabledLog()
        store.diagnostics = log
        log.record(.ambientStop, [.reason: .token("route_change")])
        await store.upsert(host)
        await store.connect(host.id)
        try await waitUntil { try await first.sentFrames().count == 1 }
        try await first.push(Self.hello(collecting: true))
        try await waitUntil { try await Self.diagnostics(first).contains { $0.name == .ambientStop } }
        let names = try await Self.diagnostics(first).map(\.name)
        #expect(names.first == .appInfo)
        #expect(names.contains(.connectionState))

        await first.fail()
        try await waitUntil { await MainActor.run { store.snapshots[host.id]?.state != .ready } }
        log.record(.routeChange, [.reason: .token("old_device_unavailable")])
        try await waitUntil { try await second.sentFrames().count == 1 }
        try await second.push(Self.hello(collecting: true))
        try await waitUntil { try await Self.diagnostics(second).contains { $0.name == .routeChange } }
        #expect(try await Self.diagnostics(second).contains { $0.fields[.state] == .token("reconnecting") })
        await store.disconnect(host.id)
    }

    @Test func aHostThatDoesNotCollectIsNeverSentAnything() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: host.url)
        let store = HostConnectionStore(connector: connector, sleep: { _ in }, jitter: { 0 })
        let log = enabledLog()
        store.diagnostics = log
        await store.upsert(host)
        await store.connect(host.id)
        try await waitUntil { try await socket.sentFrames().count == 1 }
        try await socket.push(Self.hello(collecting: false))
        try await waitUntil { await MainActor.run { store.snapshots[host.id]?.state == .ready } }
        log.record(.ambientStart)
        for _ in 0..<20 { await Task.yield() }
        #expect(try await Self.diagnostics(socket).isEmpty)
        #expect(store.diagnosticsCollectingHost == nil)
        #expect(log.hasPending)
        await store.disconnect(host.id)
    }

    @Test func ambientStartStopCausesAndHostRefusalsAreRecorded() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let harness = AmbientListeningControllerTests.Harness()
        let controller = harness.controller, capture = harness.capture
        let log = enabledLog()
        _ = log.nextBatch()
        controller.diagnostics = log
        await controller.turnOn(for: try binding())
        await controller.turnOff()
        harness.sendError = HostConnectionFailure.remote("rate_limited: ambient segments too fast")
        await controller.turnOn(for: try binding())
        try capture.yield(sineBuffer())
        try capture.yield(sineBuffer(offset: 4_800))
        try capture.yield(sineBuffer(offset: 9_600))
        try await waitUntil { await MainActor.run { !controller.isOn } }
        let events = try #require(log.nextBatch())
        #expect(events.map(\.name) == [.ambientStart, .ambientStop, .ambientStart, .hostRefusal, .ambientStop])
        #expect(events[1].fields == [.reason: .token("user")])
        #expect(events[3].fields == [.code: .token("rate_limited")])
        #expect(events[4].fields == [.reason: .token("host_refused"), .code: .token("rate_limited")])
    }
}
