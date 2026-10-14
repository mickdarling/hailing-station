#if os(macOS)
import AppKit
import HailCoaching
import HailCore

/// One playback owner and capture admission survive closing/reopening the station window (#266).
@MainActor
final class DesktopStationAudio {
    let coaching = LocalCoachingController(rendererEnvironment: MacCoachingSettings.rendererEnvironment)
    let exclusion = CoachingCaptureExclusion()
    let echoGuard: AmbientReplyEchoGuard
    let playback: ReplyPlaybackController

    private let terminationAdmission = UUID()

    func shutdown() -> Task<Void, Never> {
        exclusion.claim(terminationAdmission)
        playback.beginCaptureSuppression()
        return coaching.shutdown()
    }

    init() {
        let guardOwner = AmbientReplyEchoGuard()
        let player = ReplyPlaybackController(player: guardOwner.guarding(PCM16AudioPlayer()))
        guardOwner.follow(player)
        echoGuard = guardOwner
        playback = player
    }
}

/// AppKit keeps the process alive until the coaching owner's retirement completes.
@MainActor
final class DesktopStationAppDelegate: NSObject, NSApplicationDelegate {
    let audio = DesktopStationAudio()
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        let retirement = audio.shutdown()
        Task {
            await retirement.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
