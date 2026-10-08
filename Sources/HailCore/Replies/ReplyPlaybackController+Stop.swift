import Foundation

extension ReplyPlaybackController {
    /// The host's `stop_playback` (#309): silence the player at once and drop that host's queued replies.
    /// The player is shared, so whatever it was playing or holding stops too, whichever host sent it. Every
    /// stopped reply is marked complete, so its later frames are ignored instead of starting it again.
    func stopPlayback(from endpointID: HostEndpoint.Identifier) {
        let stopped = Set(playbackOrder).union(queue.filter { $0.endpointID == endpointID })
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
