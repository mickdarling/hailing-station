import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #614: the device asks a capable host for its doctor summary once its connection is ready, keeps the answer per
/// host, and words it itself.
@MainActor
@Suite struct HostConnectionHealthTests {
    private let rig = HostConnectionStoreAmbientBindingTests()
    private static let report = HostHealth(version: "0.1.0", build: "0123456789abcdef", checks: [
        .init(name: "daemon_running", ok: true), .init(name: "listener_ready", ok: false)
    ])

    private func healthRequests(_ socket: ScriptedSocket) async throws -> Int {
        try await socket.sentFrames().count { $0.payload == .control(.health) }
    }

    @Test func aCapableHostIsAskedWhenReadyAndOnRequest() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", HostHealth.capability])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await waitUntil { try await healthRequests(socket) == 1 }
        try await socket.push(FrameCoding.encode(Frame(timestamp: 1, source: "host",
                                                       payload: .control(.healthReport(Self.report)))))
        try await waitUntil { await MainActor.run { store.health[endpoint.id]?.report == Self.report } }
        #expect(store.health[endpoint.id]?.isStale(for: store.snapshots[endpoint.id]) == false)
        #expect(store.replyFrames.isEmpty) // a notice, never a reply
        store.requestHealth(endpoint.id)
        try await waitUntil { try await healthRequests(socket) == 2 }
        await store.disconnect(endpoint.id)
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state != .ready } }
        // Kept after the connection ends, but marked as from an earlier connection.
        #expect(store.health[endpoint.id]?.isStale(for: store.snapshots[endpoint.id]) == true)
        await store.remove(endpoint.id)
        #expect(store.health[endpoint.id] == nil)
    }

    @Test func aHostWithoutTheCapabilityIsNeverAsked() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping"])
        ready.store.requestHealth(ready.endpoint.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await healthRequests(ready.socket) == 0)
        await ready.store.disconnect(ready.endpoint.id)
    }

    @Test func theDeviceWordsTheSummaryItself() {
        #expect(Self.report.headline == "haild doctor: 1 check failed. Run haild doctor on the Mac for the fix.")
        #expect(Self.report.lines.map(\.title) == ["Daemon running", "Listener not ready"])
        #expect(Self.report.buildLine == "haild 0.1.0 · build 0123456789abcdef")
        let healthy = HostHealth(version: "0.1.0", build: nil, checks: [.init(name: "daemon_running", ok: true)])
        #expect(healthy.headline == "haild doctor: all checks pass" && healthy.buildLine == "haild 0.1.0")
        for name in HostHealth.checkNames {
            #expect(HostHealth.title(for: name, ok: true) != name && HostHealth.title(for: name, ok: false) != name)
        }
    }
}
