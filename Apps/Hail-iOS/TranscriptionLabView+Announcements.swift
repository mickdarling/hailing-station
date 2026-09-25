import HailCore
import SwiftUI
import UIKit

private let terminalPlaybackFailures: Set<String> = [
    "Playback could not resume", "Audio format is not yet playable",
    "Conflicting audio segment refused", "Playback failed", "Replay failed"
]
private let replayRefusalNotices = [
    "Replay available after listening": "Replay was not started while listening",
    "Replay available when this reply finishes": "Replay was not started while another reply was speaking"
]

extension ReplyPlaybackController {
    var terminalReplyFailureStatuses: [String: String] {
        Dictionary(uniqueKeysWithValues: replies.compactMap { reply in
            let current = status(for: reply)
            return terminalPlaybackFailures.contains(current) ? (reply.id, current) : nil
        })
    }
}

extension TranscriptionLabView {
    @MainActor
    func announceStatusIfNeeded(_ current: String) {
        // Keep the result while inactive; only the actual announcement waits for a safe audio path (#86).
        guard UIAccessibility.isVoiceOverRunning else { return }
        deferredStatusAnnouncement = current
        announceDeferredStatusIfNeeded()
    }

    @MainActor
    func announceDeferredStatusIfNeeded() {
        // Capture release and reply state can change in the same view update. Coalesce their callbacks
        // before posting, so VoiceOver receives one request-and-reply result rather than interruptions.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            flushDeferredStatusIfNeeded()
        }
    }

    @MainActor
    private func flushDeferredStatusIfNeeded() {
        guard scenePhase == .active, UIAccessibility.isVoiceOverRunning,
              !ownsCaptureSuppression, !isReplySpeaking else { return }
        let currentStatus = deferredStatusAnnouncement == status ? deferredStatusAnnouncement : nil
        let currentReply = deferredReplyAnnouncement == replyPlaybackStatus
            ? deferredReplyAnnouncement : nil
        let controlledFailure = deferredControlledReplyFailure == controlledReplyPlaybackStatus
            ? deferredControlledReplyFailure : nil
        let otherFailures = Set<String>(deferredReplyFailures.compactMap { element -> String? in
            let (id, failure) = element
            guard replyFailureStatuses[id] == failure else { return nil }
            return id == selectedReplyID ? nil : failure
        })
        self.deferredStatusAnnouncement = nil
        deferredReplyAnnouncement = nil
        deferredControlledReplyFailure = nil
        deferredReplyFailures.removeAll()
        let replayNotice = deferredReplayNotice
        deferredReplayNotice = nil
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
        if let controlledFailure, controlledFailure != currentReply {
            announcement.append("Other playback: \(controlledFailure)")
        }
        for failure in otherFailures.sorted() where failure != controlledFailure {
            announcement.append("Other reply: \(failure)")
        }
        if let replayNotice { announcement.append(replayNotice) }
        guard !announcement.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: announcement.joined(separator: ". "))
    }

    var isReplySpeaking: Bool { globalReplyAudioSpeaking }

    @MainActor
    func announceReplyStatusIfNeeded(_ current: String?) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        if current == "Replaying" { deferredReplayNotice = nil }
        if let current, [
                "Paused", "Muted", "Played", "Playback failed", "Replay failed",
                "Playback could not resume", "Audio format is not yet playable",
                "Conflicting audio segment refused", "Replay available after listening",
                "Replay available when this reply finishes"
        ].contains(current) {
            if let notice = replayRefusalNotices[current] {
                deferredReplayNotice = notice
            } else {
                deferredReplyAnnouncement = current
            }
        }
        announceDeferredStatusIfNeeded()
    }

    @MainActor
    func announceControlledReplyFailureIfNeeded(_ current: String?) {
        guard UIAccessibility.isVoiceOverRunning,
              let current, current != replyPlaybackStatus else { return }
        if current == "Replaying" { deferredReplayNotice = nil; return }
        if let notice = replayRefusalNotices[current] {
            deferredReplayNotice = notice
        } else {
            guard terminalPlaybackFailures.contains(current),
                  !replyFailureStatuses.values.contains(current) else { return }
            deferredControlledReplyFailure = current
        }
        announceDeferredStatusIfNeeded()
    }

    @MainActor
    func announceNewReplyFailures(previous: [String: String], current: [String: String]) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        for (id, failure) in current where previous[id] != failure {
            deferredReplyFailures[id] = failure
        }
        announceDeferredStatusIfNeeded()
    }
}

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
}
