import HailCore

extension TranscriptionLabView {
    @MainActor var dockTalk: TalkActivity {
        let available = talkSession.owner.map { $0 == captureOwnerID } ?? true
        let phase = TalkCapturePhase(starting: isStarting || startTask != nil, recording: isRecording,
                                     finishing: isFinalizing || finishTask != nil)
        return TalkActivity(phase: available ? phase : nil, sendPending: pendingSendID != nil,
                            interrupting: isInterrupting || interruptTask != nil)
    }

    /// Refresh the installed owner's state for each tap, including actions queued by accessibility.
    @MainActor @discardableResult
    func dispatchDockPrimary(_ intent: VoiceDockIntent, destination: DestinationControlState,
                             accessories: DockAccessories) -> Task<Void, Never>? {
        let current = VoiceDockState.resolve(talk: dockTalk, destination: destination, accessories: accessories)
        guard current.primaryIntent == intent else { return nil }
        switch intent {
        case .finish: return finishTalk()
        case .talk: return startTalk()
        default: return nil
        }
    }

    @MainActor @discardableResult
    func startTalk() -> Task<Void, Never> {
        let task = Task { await begin() }
        startTask = task
        return task
    }

    @MainActor @discardableResult
    func finishTalk() -> Task<Void, Never> {
        Task { await finish() }
    }
}
