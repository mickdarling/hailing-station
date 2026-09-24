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

    var isReplySpeaking: Bool {
        globalReplyAudioSpeaking
    }

    @MainActor
    func announceReplyStatusIfNeeded(_ current: String?) {
        guard scenePhase == .active, UIAccessibility.isVoiceOverRunning else { return }
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
        guard scenePhase == .active, UIAccessibility.isVoiceOverRunning,
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
