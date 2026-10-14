#if os(macOS)
import HailCoaching
import HailCore

/// One playback owner and capture admission survive closing/reopening the station window (#266).
@MainActor
final class DesktopStationAudio {
    let coaching = LocalCoachingController(rendererEnvironment: MacCoachingSettings.rendererEnvironment)
    let exclusion = CoachingCaptureExclusion()
    let echoGuard: AmbientReplyEchoGuard
    let playback: ReplyPlaybackController

    init() {
        let guardOwner = AmbientReplyEchoGuard()
        let player = ReplyPlaybackController(player: guardOwner.guarding(PCM16AudioPlayer()))
        guardOwner.follow(player)
        echoGuard = guardOwner
        playback = player
    }
}
#endif
