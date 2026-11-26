import Foundation
import HailCore
typealias StationConversationDestinationID = TalkDestinationID

@MainActor
struct StationTalkRoute {
    let store: HostConnectionStore
    let selected: () -> TalkDestinationID?
    let reportRemoval: (TalkSendRefusal) -> Void
    func binding(for shown: TalkDestinationID?) -> TalkDestinationBinding? {
        guard let shown, selected() == shown else { return nil }
        return store.talkBinding(for: shown)
    }
}

@MainActor
extension TranscriptionLabView {
    func begin(whenVisible isVisible: @MainActor () -> Bool) async {
        guard isVisible(), !isRecording, !isStarting, !isFinalizing, !isInterrupting,
              finishTask == nil, interruptTask == nil, pendingSendID == nil, !Task.isCancelled, scenePhase == .active,
              talkSession.admit(captureOwnerID, receive: receiveResult, cleanup: { await self.finish(force: true) })
        else {
            startTask = nil
            return
        }
        recordingDestination = selectedBinding
        recordingGeneration = destinationGeneration
        takeCaptureExclusivity()
        isStarting = true
        hasReceivedAudio = false
        (finalText, volatileText) = ("", "")
        defer {
            isStarting = false
            startTask = nil
            retireTalkIfIdle()
            restorePlaybackIfRequestedAndReady()
        }
        guard await prepareCaptureAuthorization() else { return }
        do {
            try await quietReplyAudio()
            try Task.checkCancellation()
            talkStatus = .message("Preparing on-device speech model…")
            try await audioSession.activate()
            let utteranceID = try await transcriber.start()
            activeUtteranceID = utteranceID
            try Task.checkCancellation()
            guard isVisible(), scenePhase == .active else { throw CancellationError() }
            let buffers = try capture.start()
            isRecording = true
            talkStatus = .message("Listening")
            bufferTask = Task { await consumeCapture(buffers, utteranceID: utteranceID) }
        } catch is CancellationError {
            await handleStartCancellation()
        } catch {
            _ = await cleanUp()
            releaseCaptureExclusivityAfterWork()
            talkStatus = .message("Could not start: \(error.localizedDescription)")
        }
    }
    private func consumeCapture(_ buffers: AsyncStream<AudioCaptureBuffer>, utteranceID: UUID) async {
        guard activeUtteranceID == utteranceID else { return }
        // finish/interrupt already own cleanup and can be awaiting this task. Never await ourselves or send a
        // partial request merely because the microphone ended. Unowned normal, failed and cancelled ends only
        // retire consumer liveness; they do not finalize the lab or discard the text that Finish will send.
        do {
            try await CapturePlaybackSuppression.consume(buffers, owner: captureOwnerID, transitioning: { [self] in
                isStarting || isFinalizing || isInterrupting || startTask != nil || finishTask != nil
            }, receive: {
                guard !Task.isCancelled, activeUtteranceID == utteranceID else { return }
                markAudioReceived()
                try await transcriber.consume($0)
            })
        } catch {
            guard activeUtteranceID == utteranceID else { return } // Escape may replace capture while consume awaits.
            talkStatus = .message("Capture failed: \(error.localizedDescription)")
        }
    }
    func finish(force: Bool = false) async {
        guard talkSession.owner == captureOwnerID else {
            if force, let pendingStart = startTask {
                pendingStart.cancel()
                await pendingStart.value
            }
            return
        }
        // Never takes suppression (#760): with a finish pending and no hold, the capture is already stopped.
        if force { isForcedTeardown = true }
        if force, let pendingFinish = finishTask {
            finishGeneration = UUID()
            finishTask = Task {
                await deactivateTalkRoute()
                await pendingFinish.value
            }
        } else if finishTask == nil {
            finishGeneration = UUID()
            finishTask = Task { await performFinish(force: force) }
        }
        guard let generation = finishGeneration else { return }
        await finishTask?.value
        completeFinish(generation: generation)
    }
    func completeFinish(generation: UUID) {
        guard finishGeneration == generation else { return }
        finishGeneration = nil
        finishTask = nil
        retireTalkIfIdle()
        restorePlaybackAfterFinish()
    }
    private func performFinish(force: Bool) async {
        if force, await prepareForcedFinish() { return }
        if force, pendingSendID != nil, !isRecording, bufferTask == nil, activeUtteranceID == nil {
            await deactivateTalkRoute()
            return
        }
        guard !isInterrupting, !isFinalizing, force || isRecording || bufferTask != nil else { return }
        isFinalizing = true
        defer { isFinalizing = false }
        talkStatus = .message("Finalizing…")
        let finalized = await cleanUp()
        if !force && isForcedTeardown { await deactivateTalkRoute() }
        releaseCaptureExclusivityAfterWork()
        let text = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBinding = if force || isForcedTeardown, let route, let admitted = recordingDestination {
            route.store.talkBinding(for: admitted.destination) // Inactivity can hide the still-selected target.
        } else {
            recordingGeneration == destinationGeneration ? selectedBinding : nil
        }
        if !text.isEmpty, onFinalized != nil, recordingDestination == nil || recordingDestination != currentBinding {
            (finalText, volatileText) = (text, "")
            return refuseRecording(.destinationChanged)
        }
        guard !force, !isForcedTeardown else { talkStatus = .ready; return }
        guard !text.isEmpty else { talkStatus = .message("Nothing heard"); return }
        (finalText, volatileText) = (text, "")
        guard onFinalized != nil, let recordingDestination else { talkStatus = .ready; return }
        await send(text, failurePrefix: "Send failed", admitted: recordingDestination)
    }
    func interruptTarget(using action: @MainActor () async throws -> Void) async {
        guard !isInterrupting else { return }
        if let pendingDestinationID { Self.uncorrelatedDestinations.insert(pendingDestinationID) }
        clearPendingSend()
        isInterrupting = true
        defer {
            isInterrupting = false
            retireTalkIfIdle()
            restorePlaybackIfRequestedAndReady()
        }
        let discardedUtterance = isStarting || isRecording || bufferTask != nil || activeUtteranceID != nil
        let pendingStart = startTask
        pendingStart?.cancel()
        if talkSession.owner == captureOwnerID { capture.stop() }
        let consumer = bufferTask
        consumer?.cancel()
        isRecording = false
        activeUtteranceID = nil
        if discardedUtterance {
            finalText = ""
            volatileText = ""
        }
        do {
            try await action()
            talkStatus = .message("Escape sent")
        } catch {
            talkStatus = .message("Escape failed: \(error.localizedDescription)")
        }
        if discardedUtterance { await transcriber.cancel() }
        await pendingStart?.value
        await consumer?.value
        bufferTask = nil
        releaseCaptureExclusivityAfterWork()
    }
    private func handleStartCancellation() async {
        if isInterrupting {
            await discardCapture()
        } else {
            _ = await cleanUp()
            talkStatus = .ready
        }
        releaseCaptureExclusivityAfterWork()
    }
    private func cleanUp() async -> String {
        capture.stop()
        let task = bufferTask
        bufferTask = nil
        await task?.value
        let finalized = await transcriber.stop()
        activeUtteranceID = nil
        isRecording = false
        return finalized
    }
    private func retireTalkIfIdle() {
        guard !isStarting, !isRecording, !isFinalizing, !isInterrupting, finishTask == nil else { return }
        talkSession.retire(captureOwnerID)
    }
}
