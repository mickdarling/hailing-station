import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #735 H-4 on the device: the card's duck mode text, its end note, and the end control, which goes only to a host that
/// offers `end_duck_mode` and never changes the state by itself. Synthetic only.
@MainActor
@Suite struct HostConnectionDuckModeEndTests {
    private let rig = HostConnectionStoreAmbientBindingTests()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func push(_ control: ControlPayload, on socket: ScriptedSocket) async throws {
        try await socket.push(FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control))))
    }

    @Test func theCardSaysHowItEndsAndHidesOnceOffOrPastItsEnd() {
        let later = now.addingTimeInterval(3_600)
        let style = Date.FormatStyle.dateTime.hour().minute()
        let timed = DuckModeStatus(on: true, reason: "voice", expires: later, changed: now)
        #expect(timed.detail(now: now, timeStyle: style)
            == "Thinking out loud. Say the assistant's name and \u{201C}done thinking\u{201D} to end it. "
            + "It ends by itself at \(later.formatted(style)).")
        #expect(DuckModeStatus(on: true).detail(now: now)
            == "Thinking out loud. Say the assistant's name and \u{201C}done thinking\u{201D} to end it.")
        #expect(timed.detail(now: later) == nil)
        #expect(DuckModeStatus(on: false, reason: "timeout").detail(now: now) == nil)
    }

    @Test(arguments: [("voice", "Duck mode ended when you said so."), ("timeout", "Duck mode ended by itself."),
                      ("device", "Duck mode ended from this device.")])
    func theEndNoteSaysWhyThenFades(_ reason: String, _ note: String) {
        let off = DuckModeStatus(on: false, reason: reason, changed: now)
        #expect(off.endedDetail(now: now) == note)
        #expect(off.endedDetail(now: now.addingTimeInterval(DuckModeStatus.endedNoteDuration - 1)) == note)
        #expect(off.endedDetail(now: now.addingTimeInterval(DuckModeStatus.endedNoteDuration)) == nil)
    }

    @Test func anUnknownOrMissingReasonIsAPlainEndAndAnOnModeHasNoEndNote() {
        #expect(DuckModeStatus(on: false, changed: now).endedDetail(now: now) == "Duck mode ended.")
        #expect(DuckModeStatus.ended(reason: "unsupported") == "Duck mode ended.")
        #expect(DuckModeStatus(on: true, changed: now).endedDetail(now: now) == nil)
        // On, past its expiry, before the host's "off": it reads as having ended by itself.
        let lapsed = DuckModeStatus(on: true, expires: now, changed: now.addingTimeInterval(-60))
        #expect(lapsed.endedDetail(now: now) == "Duck mode ended by itself.")
        #expect(lapsed.endedDetail(now: now.addingTimeInterval(DuckModeStatus.endedNoteDuration)) == nil)
    }

    @Test func theEndControlGoesToAHostThatOffersIt() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", "stream_audio", DuckMode.endCapability])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        #expect(!store.canEndDuckMode(endpoint.id)) // nothing to end yet
        try await push(.duckMode(on: true, reason: "voice"), on: socket)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == true } }
        #expect(store.canEndDuckMode(endpoint.id))
        try await store.endDuckMode(host: endpoint.id)
        try await waitUntil { try await socket.sentFrames().contains { $0.payload == .control(.endDuckMode) } }
        // The state follows the host, never the tap.
        #expect(store.duckMode[endpoint.id]?.on == true)
        try await push(.duckMode(on: false, reason: "device"), on: socket)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == false } }
        #expect(store.duckMode[endpoint.id]?.endedDetail() == "Duck mode ended from this device.")
        #expect(!store.canEndDuckMode(endpoint.id))
        await store.disconnect(endpoint.id)
    }

    /// An older host does not offer it: no control, and a send is refused before anything reaches the socket.
    @Test func anOlderHostIsNeverSentIt() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await push(.duckMode(on: true, reason: "voice"), on: socket)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == true } }
        #expect(!store.canEndDuckMode(endpoint.id))
        await #expect(throws: HostConnectionFailure.unsupportedCapability(DuckMode.endCapability)) {
            try await store.endDuckMode(host: endpoint.id)
        }
        #expect(try await !socket.sentFrames().contains { $0.payload == .control(.endDuckMode) })
        await store.disconnect(endpoint.id)
    }

    /// An on mode past its expiry offers no end control, even before the host's "off".
    @Test func aLapsedModeOffersNoEndControl() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", "stream_audio", DuckMode.endCapability])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await push(.duckMode(on: true, reason: "voice", expires: 1_000), on: socket)
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == true } }
        #expect(!store.canEndDuckMode(endpoint.id))
        await store.disconnect(endpoint.id)
    }
}
