import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #612: the device advertises `media_mode`, keeps each host's last media mode state, forgets it when that host's
/// connection ends, and says what the ambient card shows.
@MainActor
@Suite struct HostConnectionMediaModeTests {
    private let rig = HostConnectionStoreAmbientBindingTests()

    private func push(_ control: ControlPayload, on socket: ScriptedSocket) async throws {
        try await socket.push(FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(control))))
    }

    @Test func theHelloAdvertisesMediaModeAndTheStateFollowsTheHost() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        guard case .control(.hello(let info))? = try await socket.sentFrames().first?.payload else {
            Issue.record("expected the device hello first")
            return
        }
        #expect(info.capabilities.contains(MediaMode.capability))
        try await push(.mediaMode(on: true, reason: "voice", expires: 1_758_210_851_000), on: socket)
        try await waitUntil { await MainActor.run { store.mediaMode[endpoint.id]?.on == true } }
        #expect(store.mediaMode[endpoint.id]?.expires == Date(timeIntervalSince1970: 1_758_210_851))
        #expect(store.mediaMode[endpoint.id]?.reason == "voice")
        try await push(.mediaMode(on: false, reason: "timeout"), on: socket)
        try await waitUntil { await MainActor.run { store.mediaMode[endpoint.id]?.on == false } }
        #expect(store.replyFrames.isEmpty) // a notice, never a reply
        #expect(store.conversation.entries.isEmpty)
        await store.disconnect(endpoint.id)
    }

    /// A host keeps media mode per connection, so the device forgets it when that connection ends.
    @Test func theStateIsForgottenWhenTheConnectionEnds() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping", "select_target", "stream_audio"])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await push(.mediaMode(on: true, reason: "voice"), on: socket)
        try await waitUntil { await MainActor.run { store.mediaMode[endpoint.id]?.on == true } }
        await store.disconnect(endpoint.id)
        try await waitUntil { await MainActor.run { store.mediaMode[endpoint.id] == nil } }
    }

    @Test func theCardSaysHowItEndsAndHidesOnceOffOrPastItsEnd() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = now.addingTimeInterval(3_600)
        let style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: .gmt)
        let timed = MediaModeStatus(on: true, reason: "voice", expires: later)
        #expect(timed.detail(now: now, timeStyle: style)?.contains(later.formatted(style)) == true)
        #expect(timed.detail(now: now, timeStyle: style)?.contains("done watching") == true)
        #expect(MediaModeStatus(on: true).detail(now: now)?.contains("done watching") == true)
        #expect(timed.detail(now: later.addingTimeInterval(1)) == nil)
        #expect(MediaModeStatus(on: false, reason: "timeout").detail(now: now) == nil)
        #expect(MediaModeStatus(on: false, expires: later).expires == nil)
    }
}
