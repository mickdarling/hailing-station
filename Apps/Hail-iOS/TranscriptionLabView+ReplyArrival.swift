import HailCore

extension TranscriptionLabView {
    @MainActor
    func noteReplyArrival(previous: Set<String>, current: Set<String>) {
        guard !current.subtracting(previous).isEmpty, let destinationID else { return }
        if Self.uncorrelatedDestinations.contains(destinationID) {
            if pendingSendID == nil, !showsActivity, !isInterrupting,
               interruptTask == nil, finishTask == nil { status = "Reply received — turn unverified" }
            return
        }
        guard pendingDestinationID == destinationID,
              status == "Sending…" || status == "Waiting for reply…" else { return }
        clearPendingSend()
        status = "Reply received"
    }

    @MainActor
    func clearPendingSend() {
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        pendingSendID = nil
        pendingDestinationID = nil
    }
}
