import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #735 S-6 on the device: the privacy switch goes only to a host that offers `set_privacy`, is shown only while
/// listening, and shows PRIVATE only once the host's `duck_mode` notice confirmed it on a live connection. Every
/// unconfirmed state (unknown, connecting, stale, lapsed, a tap waiting for its notice) shows not private. Synthetic
/// only.
@MainActor
@Suite struct HostConnectionPrivacySwitchTests {
    private let rig = HostConnectionStoreAmbientBindingTests()
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private static let capable = ["ping", "select_target", "stream_audio", DuckMode.privacySwitchCapability]

    private func push(_ control: ControlPayload, on socket: ScriptedSocket) async throws {
        try await socket.push(FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control))))
    }

    @Test func privateOnlyWhenTheHostConfirmedItOnALiveConnection() {
        let on = DuckModeStatus(on: true, reason: "device"), off = DuckModeStatus(on: false, reason: "device")
        #expect(PrivacySwitchStatus(ready: true, duck: on, requested: nil, now: now).shown == .confirmedPrivate)
        #expect(PrivacySwitchStatus(ready: true, duck: on, requested: nil, now: now).isPrivate)
        #expect(PrivacySwitchStatus(ready: true, duck: off, requested: nil, now: now).shown == .confirmedNotPrivate)
        // Unknown: no notice yet.
        #expect(PrivacySwitchStatus(ready: true, duck: nil, requested: nil, now: now).shown == .unconfirmed)
        // Connecting or stale: a connection that is not ready never confirms, whatever it last said.
        #expect(PrivacySwitchStatus(ready: false, duck: on, requested: nil, now: now).shown == .unconfirmed)
        // A lapsed on notice no longer confirms.
        let lapsed = DuckModeStatus(on: true, reason: "voice", expires: now)
        #expect(!PrivacySwitchStatus(ready: true, duck: lapsed, requested: nil, now: now).isPrivate)
    }

    /// A tap waiting for its notice shows not private and pending, in either direction, until the notice arrives or
    /// the wait times out; then the host's last confirmed state shows again.
    @Test(arguments: [true, false]) func aPendingTapIsNotPrivate(_ asked: Bool) {
        let on = DuckModeStatus(on: true, reason: "voice")
        let tap = PrivacyRequest(on: asked, at: now)
        let waiting = PrivacySwitchStatus(ready: true, duck: on, requested: tap, now: now)
        #expect(waiting.pending && waiting.shown == .unconfirmed && !waiting.isPrivate)
        #expect(waiting.title == "Recording may be on")
        let late = now.addingTimeInterval(PrivacySwitchStatus.pendingTimeout)
        let timedOut = PrivacySwitchStatus(ready: true, duck: on, requested: tap, now: late)
        #expect(!timedOut.pending && timedOut.isPrivate)
        let unknown = PrivacySwitchStatus(ready: true, duck: nil, requested: tap, now: late)
        #expect(!unknown.pending && unknown.title == "Recording may be on")
        #expect(!PrivacySwitchStatus(ready: false, duck: on, requested: tap, now: now).pending)
    }

    @Test func theWordsNeverClaimPrivacyUnconfirmed() {
        #expect(PrivacySwitchStatus(ready: true, duck: DuckModeStatus(on: true), requested: nil, now: now).title
            == "Private")
        #expect(PrivacySwitchStatus(ready: true, duck: DuckModeStatus(on: false), requested: nil, now: now).title
            == "Not private")
        for status in [PrivacySwitchStatus(ready: true, duck: nil, requested: nil, now: now),
                       PrivacySwitchStatus(ready: false, duck: DuckModeStatus(on: true), requested: nil, now: now)] {
            #expect(status.title == "Recording may be on" && !status.detail.hasPrefix("The Mac confirmed"))
        }
    }

    /// The tap sends `set_privacy`; the switch waits, not private, and shows PRIVATE only after the host's notice.
    @Test func theSwitchFollowsTheHostNoticeNotTheTap() async throws {
        let ready = try await rig.readyStore(capabilities: Self.capable)
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        #expect(store.canSetPrivacy(endpoint.id))
        #expect(store.privacySwitch(endpoint.id).shown == .unconfirmed) // unknown until the host says
        try await store.setPrivacy(on: true, host: endpoint.id)
        try await waitUntil { try await socket.sentFrames().contains { $0.payload == .control(.setPrivacy(on: true)) } }
        let waiting = store.privacySwitch(endpoint.id)
        #expect(waiting.pending && !waiting.isPrivate && store.duckMode[endpoint.id] == nil)
        try await push(.duckMode(on: true, reason: "device"), on: socket)
        try await waitUntil { await MainActor.run { store.privacySwitch(endpoint.id).isPrivate } }
        #expect(!store.privacySwitch(endpoint.id).pending && store.privacyLocal[endpoint.id]?.request == nil)
        try await store.setPrivacy(on: false, host: endpoint.id)
        #expect(!store.privacySwitch(endpoint.id).isPrivate) // pending off reads not private at once
        try await push(.duckMode(on: false, reason: "device"), on: socket)
        try await waitUntil { await MainActor.run { store.privacySwitch(endpoint.id).shown == .confirmedNotPrivate } }
        await store.disconnect(endpoint.id)
    }

    /// The switch shows only while listening, and only on a host that offers it; an older host is never sent it.
    @Test func hiddenWhenNotListeningOrOnAnOlderHost() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        #expect(!store.canSetPrivacy(endpoint.id))
        #expect(!store.showsPrivacySwitch(endpoint.id, listening: true))
        await #expect(throws: HostConnectionFailure.unsupportedCapability(DuckMode.privacySwitchCapability)) {
            try await store.setPrivacy(on: true, host: endpoint.id)
        }
        #expect(store.privacyLocal[endpoint.id]?.request == nil)
        #expect(try await !socket.sentFrames().contains { $0.payload == .control(.setPrivacy(on: true)) })
        await store.disconnect(endpoint.id)
        let capable = try await rig.readyStore(capabilities: Self.capable)
        #expect(capable.store.showsPrivacySwitch(capable.endpoint.id, listening: true))
        #expect(!capable.store.showsPrivacySwitch(capable.endpoint.id, listening: false))
        await capable.store.disconnect(capable.endpoint.id)
    }

    /// A dropped or reconnecting connection clears the indicator and any waiting tap: confirmed privacy does not
    /// outlive the connection it was confirmed on.
    @Test func aDisconnectOrReconnectClearsTheIndicator() async throws {
        let ready = try await rig.readyStore(capabilities: Self.capable)
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await push(.duckMode(on: true, reason: "device"), on: socket)
        try await waitUntil { await MainActor.run { store.privacySwitch(endpoint.id).isPrivate } }
        try await store.setPrivacy(on: false, host: endpoint.id)
        await store.disconnect(endpoint.id)
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.state != .ready } }
        let gone = store.privacySwitch(endpoint.id)
        #expect(gone.shown == .unconfirmed && !gone.pending && !gone.isPrivate)
        #expect(store.duckMode[endpoint.id] == nil && store.privacyLocal[endpoint.id]?.request == nil)
        #expect(!store.showsPrivacySwitch(endpoint.id, listening: true))
    }
}
