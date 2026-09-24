import SwiftUI
import UIKit

extension TranscriptionLabView {
    func replyStatusLabel(_ raw: String) -> String {
        switch raw {
        case "Received": "Text received"
        case "Waiting for audio": "Waiting for audio"
        case "Queued": "Queued"
        case "Playing": "Speaking"
        case "Replaying": "Replaying"
        case "Paused": "Paused"
        case "Paused while listening": "Paused while listening"
        case "Muted": "Muted"
        case "Played": "Finished"
        default: raw
        }
    }

    @MainActor
    func announceStatusIfNeeded(_ current: String) {
        // Spoken accessibility feedback must not become microphone input (#86).
        guard scenePhase == .active, UIAccessibility.isVoiceOverRunning else { return }
        deferredStatusAnnouncement = current
        announceDeferredStatusIfNeeded()
    }

    @MainActor
    func announceDeferredStatusIfNeeded() {
        guard scenePhase == .active, UIAccessibility.isVoiceOverRunning,
              !ownsCaptureSuppression, !isReplySpeaking else { return }
        let currentStatus = deferredStatusAnnouncement == status ? deferredStatusAnnouncement : nil
        let currentReply = deferredReplyAnnouncement == replyPlaybackStatus
            ? deferredReplyAnnouncement : nil
        self.deferredStatusAnnouncement = nil
        deferredReplyAnnouncement = nil
        // Capture-progress speech is intentionally withheld. Only a still-current terminal result
        // may be spoken after the microphone owner has released capture.
        let captureProgress = [
            "Requesting microphone and speech access…", "Preparing on-device speech model…",
            "Quieting reply audio…", "Listening", "Receiving audio", "Finalizing…"
        ]
        var announcement: [String] = []
        if let currentStatus, !captureProgress.contains(currentStatus) {
            announcement.append(currentStatus)
        }
        if let currentReply { announcement.append("Reply \(replyStatusLabel(currentReply))") }
        guard !announcement.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: announcement.joined(separator: ". "))
    }

    var isReplySpeaking: Bool {
        globalReplyAudioSpeaking
    }

    @MainActor
    func announceReplyStatusIfNeeded(_ current: String?) {
        guard scenePhase == .active, UIAccessibility.isVoiceOverRunning else { return }
        if let current, [
                "Paused", "Muted", "Played", "Playback failed", "Replay failed",
                "Playback could not resume", "Audio format is not yet playable",
                "Conflicting audio segment refused", "Replay available after listening",
                "Replay available when this reply finishes"
        ].contains(current) {
            deferredReplyAnnouncement = current
        }
        announceDeferredStatusIfNeeded()
    }

    @MainActor
    func scheduleReplyTimeout(sendID: UUID, destinationID: ConversationDestinationID?) {
        replyTimeoutTask?.cancel()
        replyTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard pendingSendID == sendID, pendingDestinationID == destinationID,
                  status == "Waiting for reply…" else { return }
            if let destinationID {
                Self.uncorrelatedDestinations.insert(destinationID)
            }
            pendingSendID = nil
            pendingDestinationID = nil
            replyTimeoutTask = nil
            status = "No reply yet — tap to talk again"
        }
    }
}
