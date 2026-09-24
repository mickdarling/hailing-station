import SwiftUI
import UIKit

extension TranscriptionLabView {
    @MainActor
    func noteReplyArrival(previous: Set<String>, current: Set<String>) {
        guard !current.subtracting(previous).isEmpty, let destinationID else { return }
        if Self.uncorrelatedDestinations.contains(destinationID) {
            if pendingSendID == nil, !showsActivity, !isInterrupting,
               interruptTask == nil, finishTask == nil { status = "Reply arrived — turn unverified" }
            return
        }
        guard pendingDestinationID == destinationID,
              status == "Sending…" || status == "Waiting for reply…" else { return }
        clearPendingSend()
        status = "Reply arrived — turn unverified"
    }

    @MainActor
    func clearPendingSend() {
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        pendingSendID = nil
        pendingDestinationID = nil
    }

    var showsProgress: Bool {
        showsActivity || replyPlaybackStatus.map {
            ["Playing", "Replaying"].contains($0)
        } == true
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
        guard scenePhase == .active, !ownsCaptureSuppression, UIAccessibility.isVoiceOverRunning,
              replyPlaybackStatus != "Playing", replyPlaybackStatus != "Replaying" else { return }
        UIAccessibility.post(notification: .announcement, argument: current)
    }

    @MainActor
    func announceReplyStatusIfNeeded(_ current: String?) {
        guard scenePhase == .active, !ownsCaptureSuppression, UIAccessibility.isVoiceOverRunning,
              let current, ["Paused", "Muted", "Played", "Playback failed", "Replay failed"]
                .contains(current) else { return }
        UIAccessibility.post(notification: .announcement, argument: "Reply \(replyStatusLabel(current))")
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
