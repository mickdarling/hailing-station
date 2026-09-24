import HailCore
import SwiftUI

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
