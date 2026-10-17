import Foundation
import HailProtocol
#if os(iOS)
import MediaPlayer
#endif

extension ReplyPlaybackController {
    /// The headset's pause press during a reply (#269 interim): capture is half-duplex, so a spoken "mute" (#404) is
    /// not heard over a long reply. The press stops every reply playing or queued, whichever host sent it, and mutes
    /// later replies at once. The app's toggle or a spoken "unmute" undoes the mute. False when no reply is active.
    @discardableResult
    public func stopAndMuteFromHeadset() -> Bool {
        guard activeKey != nil else { return false }
        stopPlayback(from: nil)
        setMuted(true)
        return true
    }

    /// A reply started or ended: only while one is active does the headset's pause belong to Hail, so the user's
    /// music app has its controls back between replies.
    func replyActivityChanged() {
        #if os(iOS)
        HeadsetReplyCommands.shared.replyActivity(self, active: activeKey != nil)
        #endif
    }
}

#if os(iOS)
/// The system's remote commands (a headset or AirPods pause, the lock-screen pause) while a reply is active. The
/// controller that last started a reply holds them, so a throwaway controller from a repeated view init never does.
@MainActor
final class HeadsetReplyCommands {
    static let shared = HeadsetReplyCommands()
    private weak var controller: ReplyPlaybackController?
    private var targets: [(command: MPRemoteCommand, target: Any)] = []

    func replyActivity(_ controller: ReplyPlaybackController, active: Bool) {
        if active {
            self.controller = controller
            claim()
        } else if self.controller === controller {
            release()
        }
    }

    private func claim() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Hail reply"]
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        for command in [center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand] {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                guard Thread.isMainThread else {
                    Task { @MainActor in self?.press() }
                    return .success
                }
                return MainActor.assumeIsolated { self?.press() ?? .commandFailed }
            }
            targets.append((command, target))
        }
    }

    private func release() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    @discardableResult
    private func press() -> MPRemoteCommandHandlerStatus {
        controller?.stopAndMuteFromHeadset() == true ? .success : .noActionableNowPlayingItem
    }
}
#endif
