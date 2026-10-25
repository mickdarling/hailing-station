#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// The device is told before it hears (#886), as for privacy (#875): a media mode change's `media_mode` notice goes
/// out before the clip that confirms it, so "Media mode on." never plays while the app still shows media mode off, and
/// "Media mode off." never plays while it still shows on. The notice and the clip are queued in the same step on two
/// queues (the router's `mediaNotices` and the owner's voice chain); a latch holds `mediaNotices` behind the change, so
/// a clip that did not wait for its notice would be heard first. The owner's voice, on and off. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientMediaNoticeOrderTests {
    static let clips = AmbientAckLibrary(clips: [
        AmbientStopConfirmation.mediaOn: [AmbientDuckModeTests.clip("Media mode on.", 6)],
        AmbientStopConfirmation.mediaOff: [AmbientDuckModeTests.clip("Media mode off.", 7)]
    ])

    /// How long the held notice must keep the clip back. Far longer than the clip takes once nothing holds it back
    /// (tens of milliseconds), so without the wait the clip is always heard inside it.
    static let held: Duration = .seconds(2)

    @Test func theOnNoticeReachesTheDeviceBeforeMediaModeOn() async throws {
        let rig = try await Self.startedRig()
        defer { rig.close() }
        let connection = try #require(rig.connection()), router = rig.env.router
        let say = router.voiceMedia(on: connection, listener: rig.env.listener)

        let latch = MeetingLatch()
        router.mediaNotices.enqueue { await latch.wait() }
        say(true)
        #expect(router.mediaMode(connection: connection))
        #expect(await !Self.clipSaid(rig, count: 1), "the clip played while its notice was still held")
        latch.open()

        let (entry, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "media mode on")
        #expect(words == "Media mode on.")
        #expect(entry.contains { payload in
            if case .control(.mediaMode(true, "voice", _?)) = payload { true } else { false }
        })
        await rig.finish()
        #expect(rig.details("ambient_media_device").first == "on=true device=sent")
        #expect(rig.details("ambient_media_confirmed") == ["on=true confirm=confirmmediaon/0:sent"])
    }

    @Test func theOffNoticeReachesTheDeviceBeforeMediaModeOff() async throws {
        let rig = try await Self.startedRig()
        defer { rig.close() }
        let connection = try #require(rig.connection()), router = rig.env.router
        let say = router.voiceMedia(on: connection, listener: rig.env.listener)
        say(true)
        let (_, onWords) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "media mode on")
        #expect(onWords == "Media mode on.")
        #expect(await eventually { rig.details("ambient_media_confirmed").count == 1 })

        let latch = MeetingLatch()
        router.mediaNotices.enqueue { await latch.wait() }
        say(false)
        #expect(!router.mediaMode(connection: connection))
        #expect(await !Self.clipSaid(rig, count: 2), "the clip played while its notice was still held")
        latch.open()

        let (exit, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "media mode off")
        #expect(words == "Media mode off.")
        #expect(exit.contains(.control(.mediaMode(on: false, reason: "voice"))))
        await rig.finish()
        #expect(rig.details("ambient_media_device").prefix(2) == ["on=true device=sent", "on=false device=sent"])
        #expect(rig.details("ambient_media_confirmed") == ["on=true confirm=confirmmediaon/0:sent",
                                                           "on=false confirm=confirmmediaoff/0:sent"])
    }

    /// A rig whose child has started (its status answered) and is waiting, on a device that advertised `media_mode`.
    static func startedRig() async throws -> DuckRig {
        let rig = try await DuckRig(script: AmbientPrivacySwitchTests.script(), clips: clips,
                                    capabilities: [MediaMode.capability])
        #expect(await eventually { rig.details("ambient_duck_confirmed") == [AmbientPrivacySwitchTests.statusOff] })
        return rig
    }

    /// Whether the `count`th media confirmation was logged (each is logged once its clip was sent) within `held`.
    static func clipSaid(_ rig: DuckRig, count: Int) async -> Bool {
        let deadline = ContinuousClock.now + held
        while ContinuousClock.now < deadline {
            if rig.details("ambient_media_confirmed").count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return rig.details("ambient_media_confirmed").count >= count
    }
}
#endif
