import HailCore

@MainActor
extension TranscriptionLabView {
    private var talkOwnerAvailable: Bool { talkSession.owner.map { $0 == captureOwnerID } ?? true }

    func talkButtonDisabled(isVisible: Bool) -> Bool {
        !talkOwnerAvailable || startTask != nil || isStarting || isFinalizing || isInterrupting
            || finishTask != nil || interruptTask != nil
            || (!isRecording && (!isVisible || pendingSendID != nil))
    }

    var dockTalk: TalkActivity {
        let phase = TalkCapturePhase(starting: isStarting || startTask != nil, recording: isRecording,
                                     finishing: isFinalizing || finishTask != nil)
        return TalkActivity(phase: talkOwnerAvailable ? phase : nil, sendPending: pendingSendID != nil,
                            interrupting: isInterrupting || interruptTask != nil)
    }

    func dockState(destination: DestinationControlState, accessories: DockAccessories) -> VoiceDockState {
        VoiceDockState.resolve(talk: dockTalk, destination: destination, accessories: accessories)
            .allowingPrimary(!talkButtonDisabled(isVisible: isTalkVisible()))
    }

    /// Refresh the installed owner's state for each tap, including actions queued by accessibility.
    @discardableResult
    func dispatchDockPrimary(_ intent: VoiceDockIntent, destination: DestinationControlState,
                             accessories: DockAccessories) -> Task<Void, Never>? {
        let current = dockState(destination: destination, accessories: accessories)
        guard current.primaryIntent == intent else { return nil }
        switch intent {
        case .finish: return finishTalk()
        case .talk: return startTalk()
        default: return nil
        }
    }

    @discardableResult
    func startTalk() -> Task<Void, Never> {
        let task = Task { await begin(whenVisible: isTalkVisible) }
        startTask = task
        return task
    }

    func startInterrupt(using action: @escaping @MainActor () async throws -> Void) {
        guard interruptTask == nil else { return }
        interruptTask = Task {
            await interruptTarget(using: action)
            interruptTask = nil
        }
    }

    @discardableResult
    func finishTalk() -> Task<Void, Never> {
        Task { await finish() }
    }
}
