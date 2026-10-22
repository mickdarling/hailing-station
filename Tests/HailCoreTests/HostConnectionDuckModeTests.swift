import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #735: the device advertises `duck_mode`, keeps each host's last duck mode state, honours its expiry, and forgets it
/// when that host's connection ends. Off unless a host says otherwise.
@MainActor
@Suite struct HostConnectionDuckModeTests {
    private let rig = HostConnectionStoreAmbientBindingTests()

    private func push(_ control: ControlPayload, on socket: ScriptedSocket) async throws {
        try await socket.push(FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control))))
    }

    @Test func theHelloAdvertisesDuckModeAndTheStateFollowsTheHost() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        guard case .control(.hello(let info))? = try await socket.sentFrames().first?.payload else {
            Issue.record("expected the device hello first")
            return
        }
        #expect(info.capabilities.contains(DuckMode.capability))
        #expect(info.capabilities.contains(MediaMode.capability))
        #expect(store.duckMode[endpoint.id] == nil) // off until a host says otherwise
        try await push(.duckMode(on: true, reason: "voice", expires: 1_758_210_851_000), on: socket)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == true } }
        #expect(store.duckMode[endpoint.id]?.expires == Date(timeIntervalSince1970: 1_758_210_851))
        #expect(store.duckMode[endpoint.id]?.reason == "voice")
        #expect(store.mediaMode[endpoint.id] == nil) // a separate mode
        try await push(.duckMode(on: false, reason: "timeout"), on: socket)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == false } }
        #expect(store.duckMode[endpoint.id]?.reason == "timeout")
        #expect(store.replyFrames.isEmpty) // a notice, never a reply
        #expect(store.conversation.entries.isEmpty)
        await store.disconnect(endpoint.id)
    }

    /// A host keeps duck mode per connection, so the device forgets it when that connection ends.
    @Test func theStateIsForgottenWhenTheConnectionEnds() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await push(.duckMode(on: true, reason: "device"), on: socket)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == true } }
        await store.disconnect(endpoint.id)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id] == nil } }
    }

    @Test func anOnModePastItsExpiryCountsAsOff() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = now.addingTimeInterval(3_600)
        let timed = DuckModeStatus(on: true, reason: "voice", expires: later)
        #expect(timed.isOn(now: now))
        #expect(!timed.isOn(now: later))
        #expect(!timed.isOn(now: later.addingTimeInterval(1)))
        #expect(DuckModeStatus(on: true).isOn(now: now))
        #expect(!DuckModeStatus(on: false, reason: "timeout").isOn(now: now))
        #expect(DuckModeStatus(on: false, expires: later).expires == nil)
        #expect(DuckModeStatus(on: true, reason: nil, expiresMilliseconds: 1_000_000_000).expires
            == Date(timeIntervalSince1970: 1_000_000))
    }
}
