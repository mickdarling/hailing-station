#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// The device is told before it hears (#875): a privacy change's `duck_mode` notice goes out before the clip that
/// announces it, so "Recording again." never plays while the app still shows private, and "Privacy on." never plays
/// before the app is told. The notice and the clip are queued in the same step on two queues (the router's
/// `mediaNotices` and the connection's clip chain); a latch holds `mediaNotices` behind the change, so a clip that did
/// not wait for its notice would be heard first. Every path: the app's switch and the owner's voice, on and off.
/// Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyNoticeOrderTests {
    enum Source: String, CaseIterable { case device, voice }

    /// How long the held notice must keep the clip back. Far longer than the clip takes once nothing holds it back
    /// (tens of milliseconds), so without the wait the clip is always heard inside it.
    static let held: Duration = .seconds(2)

    @Test(arguments: Source.allCases) func theOffNoticeReachesTheDeviceBeforeRecordingAgain(_ source: Source)
        async throws {
        let rig = try await AmbientPrivacySwitchTests.startedRig()
        defer { rig.close() }
        let connection = try #require(rig.connection()), router = rig.env.router
        try await AmbientPrivacySwitchTests.send(true, on: rig.socket)
        let (_, onWords) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "privacy on")
        #expect(onWords == "Privacy on. I'm only listening for my name.")
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })

        let latch = MeetingLatch()
        router.mediaNotices.enqueue { await latch.wait() }
        Self.change(false, from: source, rig: rig, connection: connection)
        #expect(!router.duckMode(connection: connection))
        #expect(await !Self.clipSaid(rig, count: 3), "the clip played while its notice was still held")
        latch.open()

        let (exit, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "privacy off")
        #expect(words == "Recording again.")
        #expect(exit.contains(.control(.duckMode(on: false, reason: source.rawValue))))
        await rig.finish()
        #expect(rig.details("ambient_duck_device") == ["on=true device=sent", "on=false device=sent"])
    }

    @Test(arguments: Source.allCases) func theOnNoticeReachesTheDeviceBeforePrivacyOn(_ source: Source) async throws {
        let rig = try await AmbientPrivacySwitchTests.startedRig()
        defer { rig.close() }
        let connection = try #require(rig.connection()), router = rig.env.router

        let latch = MeetingLatch()
        router.mediaNotices.enqueue { await latch.wait() }
        Self.change(true, from: source, rig: rig, connection: connection)
        #expect(router.duckMode(connection: connection))
        #expect(await !Self.clipSaid(rig, count: 2), "the clip played while its notice was still held")
        latch.open()

        let (entry, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "privacy on")
        #expect(words == "Privacy on. I'm only listening for my name.")
        #expect(entry.contains { payload in
            if case .control(.duckMode(true, source.rawValue, nil)) = payload { true } else { false }
        })
        await rig.finish()
        #expect(rig.details("ambient_duck_device") == ["on=true device=sent"])
    }

    /// The owner's change from `source`: the app's switch, or the voice command RightyO checked (entry or exit).
    static func change(_ on: Bool, from source: Source, rig: DuckRig, connection: UUID) {
        switch source {
        case .device: rig.env.router.ambientPrivacy(on, connection: connection)
        case .voice: rig.env.router.voiceDuck(on: connection, listener: rig.env.listener)(on ? .enter : .exit)
        }
    }

    /// Whether the `count`th privacy confirmation was logged (each is logged once its clip was sent) within `held`.
    static func clipSaid(_ rig: DuckRig, count: Int) async -> Bool {
        let deadline = ContinuousClock.now + held
        while ContinuousClock.now < deadline {
            if rig.details("ambient_duck_confirmed").count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return rig.details("ambient_duck_confirmed").count >= count
    }
}
#endif
