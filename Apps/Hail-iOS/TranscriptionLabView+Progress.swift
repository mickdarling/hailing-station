import HailCore
import SwiftUI
import UIKit

private let terminalPlaybackFailures: Set<String> = [
    "Playback could not resume", "Audio format is not yet playable",
    "Conflicting audio segment refused", "Playback failed", "Replay failed"
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
    @MainActor static var uncorrelatedDestinations: Set<ConversationDestinationID> = []

    @MainActor
    func beginCaptureExclusivity() {
        isForcedTeardown = false
        playbackRestoreRequested = false
        guard !ownsCaptureSuppression else { return }
        ownsCaptureSuppression = true
        onCaptureWillBegin?(captureOwnerID)
    }

    @MainActor
    func releaseCaptureExclusivityAfterWork() {
        guard !isForcedTeardown else { return }
        endCaptureExclusivity(resumingPlayback: true)
    }

    @MainActor
    func restorePlaybackAfterForcedTeardown() {
        guard scenePhase == .active else { return }
        guard finishTask == nil, startTask == nil, !isStarting, !isFinalizing, !isInterrupting else {
            playbackRestoreRequested = true
            return
        }
        playbackRestoreRequested = false
        isForcedTeardown = false
        if ownsCaptureSuppression {
            endCaptureExclusivity(resumingPlayback: true)
        }
    }

    @MainActor
    func endCaptureExclusivity(resumingPlayback: Bool = true) {
        guard ownsCaptureSuppression else { return }
        ownsCaptureSuppression = false
        onCaptureDidEnd?(captureOwnerID, resumingPlayback)
    }

    @MainActor
    func restorePlaybackIfRequestedAndReady() {
        guard playbackRestoreRequested else { return }
        restorePlaybackAfterForcedTeardown()
    }

    @ViewBuilder
    var replyStatusSummary: some View {
        if let replyPlaybackStatus {
            HStack {
                Text("Reply: \(replyStatusLabel(replyPlaybackStatus))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("transcription.reply-status")
        }
    }

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
        let controlledFailure = deferredControlledReplyFailure == controlledReplyPlaybackStatus
            ? deferredControlledReplyFailure : nil
        let otherFailures = Set(deferredReplyFailures.compactMap { id, failure in
            replyFailureStatuses[id] == failure ? failure : nil
        })
        self.deferredStatusAnnouncement = nil
        deferredReplyAnnouncement = nil
        deferredControlledReplyFailure = nil
        deferredReplyFailures.removeAll()
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
        for failure in otherFailures.sorted() where failure != currentReply && failure != controlledFailure {
            announcement.append("Other reply: \(failure)")
        }
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
    func announceControlledReplyFailureIfNeeded(_ current: String?) {
        guard scenePhase == .active, UIAccessibility.isVoiceOverRunning,
              let current, current != replyPlaybackStatus,
              terminalPlaybackFailures.contains(current),
              !replyFailureStatuses.values.contains(current) else { return }
        deferredControlledReplyFailure = current
        announceDeferredStatusIfNeeded()
    }

    @MainActor
    func announceNewReplyFailures(previous: [String: String], current: [String: String]) {
        guard scenePhase == .active, UIAccessibility.isVoiceOverRunning else { return }
        for (id, failure) in current where previous[id] != failure {
            deferredReplyFailures[id] = failure
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
