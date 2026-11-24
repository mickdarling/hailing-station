import HailCore

extension TranscriptionLabView {
    @MainActor
    func noteReplyArrival(previous: Set<String>, current: Set<String>) {
        guard !current.subtracting(previous).isEmpty, let destinationID else { return }
        if Self.uncorrelatedDestinations.contains(destinationID) {
            if pendingSendID == nil, !showsActivity, !isInterrupting,
               interruptTask == nil, finishTask == nil {
                talkStatus = .turn(.sentUnverified, text: "Reply received — turn unverified")
            }
            return
        }
        let outcome = talkStatus.outcome()
        guard pendingDestinationID == destinationID, outcome == .sending || outcome == .waitingForReply else { return }
        answeredSendID = outcome == .sending ? pendingSendID : nil
        clearPendingSend()
        talkStatus = .turn(.replyReceived, text: "Reply received")
    }

    @MainActor
    func clearPendingSend() {
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        pendingSendID = nil
        pendingDestinationID = nil
    }
}
