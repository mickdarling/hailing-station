import Foundation
import HailProtocol

extension ReplyPlaybackController {
    /// The host's playback controls: stop (#309) and mute (#404). Any other control is not playback's to act on.
    func handlePlaybackControl(_ control: ControlPayload, _ event: HostReplyEvent) {
        guard remember(event.frame.id) else { return }
        switch control {
        case .stopPlayback: stopPlayback(from: event.endpointID)
        case .setReplyMute(let muted): setReplyMute(muted)
        default: break
        }
    }

    /// The host's `set_reply_mute` (#404), from the owner's spoken "mute" or "unmute". Unmuting is immediate. A mute
    /// lets the reply now playing finish, which is the host's spoken "Muted.", sent after its stop, so it is heard,
    /// then later replies play silently, as with the mute control. With nothing playing it applies at once.
    func setReplyMute(_ muted: Bool) {
        guard muted else {
            pendingMuteAfter = nil
            return setMuted(false)
        }
        if let activeKey, !isMuted { pendingMuteAfter = activeKey } else { setMuted(true) }
    }

    /// Applies a waiting voice mute once the reply it waited for is no longer playing.
    func applyPendingMuteIfDue() {
        guard let after = pendingMuteAfter, activeKey != after, !playbackOrder.contains(after) else { return }
        pendingMuteAfter = nil
        setMuted(true)
    }

    /// The same change as the mute control, so the indicator and status follow.
    func setMuted(_ muted: Bool) {
        if muted != isMuted { toggleMute() }
    }

    /// The host's `stop_playback` (#309): silence the player at once and drop that host's queued replies, or every
    /// host's when `endpointID` is nil (the headset's pause, `+Headset`).
    /// The player is shared, so whatever it was playing or holding stops too, whichever host sent it. Every
    /// stopped reply is marked complete, so its later frames are ignored instead of starting it again.
    func stopPlayback(from endpointID: HostEndpoint.Identifier?) {
        let stopped = Set(playbackOrder).union(queue.filter { endpointID == nil || $0.endpointID == endpointID })
        guard !stopped.isEmpty else { return }
        player.cancel()
        playbackGeneration &+= 1
        for key in stopped {
            setPresentationStatus("Stopped", for: key)
            streams[key] = nil
            completed.insert(key)
        }
        queue.removeAll { stopped.contains($0) }
        playbackOrder.removeAll()
        activeKey = nil
        isPaused = false
        status = "Stopped"
        drain()
    }

    /// A new reply arriving while playback is paused supersedes what was paused (#321): the user paused the
    /// last answer and asked again, so the newest reply plays. The paused reply and anything queued before the
    /// new one are skipped and marked complete, so their later frames are ignored instead of starting them.
    func supersedePausedReplies() {
        guard isPaused else { return }
        let skipped = Set(playbackOrder).union(queue)
        if !skipped.isEmpty {
            player.cancel()
            playbackGeneration &+= 1
        }
        for key in skipped {
            setPresentationStatus("Skipped", for: key)
            streams[key] = nil
            completed.insert(key)
        }
        queue.removeAll()
        playbackOrder.removeAll()
        activeKey = nil
        isPaused = false
    }
}
