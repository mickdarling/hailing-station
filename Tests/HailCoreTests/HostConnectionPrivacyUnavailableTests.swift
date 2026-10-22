import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Jarvis's "Privacy on · listening unavailable" (#735 S-6): privacy confirmed on, then the host ended the ambient
/// stream on the same connection (no child can keep privacy). Distinct from PRIVATE and from "Recording may be on",
/// and the switch stays usable so privacy can be turned off. Synthetic only.
@MainActor
@Suite struct HostConnectionPrivacyUnavailableTests {
    private let rig = HostConnectionStoreAmbientBindingTests()
    private static let capable = ["ping", "select_target", "stream_audio", DuckMode.privacySwitchCapability]
    private static let stopped = HostConnectionFailure.remote("not_allowed: ambient stopped: privacy unconfirmed")

    private func push(_ control: ControlPayload, on socket: ScriptedSocket) async throws {
        try await socket.push(FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control))))
    }

    private func binding(_ store: HostConnectionStore, _ id: HostEndpoint.Identifier,
                         generation: UUID? = nil) throws -> AmbientAudioBinding {
        let current = try #require(store.snapshots[id]?.connectionGeneration)
        return AmbientAudioBinding(hostID: id, targetID: "tmux:a", connectionGeneration: generation ?? current,
                                   selection: 0)
    }

    @Test func theModelSaysUnavailableOnlyWhenConfirmedAndStopped() {
        let on = DuckModeStatus(on: true, reason: "device")
        let unavailable = PrivacySwitchStatus(ready: true, duck: on, requested: nil, listeningStopped: true)
        #expect(unavailable.shown == .privateListeningUnavailable && unavailable.isPrivate)
        #expect(unavailable.title == "Privacy on \u{00B7} listening unavailable")
        #expect(unavailable.title != "Private" && unavailable.title != "Recording may be on")
        let off = DuckModeStatus(on: false, reason: "device")
        #expect(PrivacySwitchStatus(ready: true, duck: off, requested: nil, listeningStopped: true).shown
            == .confirmedNotPrivate)
        #expect(PrivacySwitchStatus(ready: false, duck: on, requested: nil, listeningStopped: true).shown
            == .unconfirmed)
        #expect(PrivacySwitchStatus(ready: true, duck: nil, requested: nil, listeningStopped: true).shown
            == .unconfirmed)
    }

    /// Privacy on, then the host's ambient stop: the unavailable state shows and the switch is offered while not
    /// listening, and turning it off sends `set_privacy` off. The host's off notice ends the state.
    @Test func privacyOnThenAmbientStoppedShowsUnavailableAndTheSwitchWorks() async throws {
        let ready = try await rig.readyStore(capabilities: Self.capable)
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await push(.duckMode(on: true, reason: "device"), on: socket)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == true } }
        #expect(!store.showsPrivacySwitch(endpoint.id, listening: false))
        store.notePrivateStop(Self.stopped, binding: try binding(store, endpoint.id))
        #expect(store.privacySwitch(endpoint.id, listening: false).shown == .privateListeningUnavailable)
        #expect(store.showsPrivacySwitch(endpoint.id, listening: false))
        // Listening again on this connection: plain PRIVATE.
        #expect(store.privacySwitch(endpoint.id, listening: true).shown == .confirmedPrivate)
        try await store.setPrivacy(on: false, host: endpoint.id)
        try await waitUntil {
            try await socket.sentFrames().contains { $0.payload == .control(.setPrivacy(on: false)) }
        }
        try await push(.duckMode(on: false, reason: "device"), on: socket)
        try await waitUntil {
            await MainActor.run { store.privacySwitch(endpoint.id, listening: false).shown == .confirmedNotPrivate }
        }
        #expect(!store.showsPrivacySwitch(endpoint.id, listening: false))
        await store.disconnect(endpoint.id)
    }

    /// Only a stop on the generation privacy was confirmed on, only an ambient stop, and only while privacy is on.
    @Test func otherStopsDoNotCount() async throws {
        let ready = try await rig.readyStore(capabilities: Self.capable)
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        store.notePrivateStop(Self.stopped, binding: try binding(store, endpoint.id))
        #expect(store.privacyLocal[endpoint.id] == nil) // privacy not confirmed yet
        try await push(.duckMode(on: true, reason: "device"), on: socket)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == true } }
        store.notePrivateStop(Self.stopped, binding: try binding(store, endpoint.id, generation: UUID()))
        store.notePrivateStop(HostConnectionFailure.remote("not_allowed: ambient target is not selected"),
                              binding: try binding(store, endpoint.id))
        store.notePrivateStop(HostConnectionFailure.notReady, binding: try binding(store, endpoint.id))
        #expect(store.privacySwitch(endpoint.id, listening: false).shown == .confirmedPrivate)
        await store.disconnect(endpoint.id)
    }

    /// A reconnect clears it, as it clears everything privacy.
    @Test func aReconnectClearsIt() async throws {
        let ready = try await rig.readyStore(capabilities: Self.capable)
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await push(.duckMode(on: true, reason: "device"), on: socket)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == true } }
        store.notePrivateStop(Self.stopped, binding: try binding(store, endpoint.id))
        #expect(store.showsPrivacySwitch(endpoint.id, listening: false))
        await store.disconnect(endpoint.id)
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state != .ready } }
        #expect(store.privacyLocal[endpoint.id] == nil && store.duckMode[endpoint.id] == nil)
        #expect(store.privacySwitch(endpoint.id, listening: false).shown == .unconfirmed)
        #expect(!store.showsPrivacySwitch(endpoint.id, listening: false))
    }
}
