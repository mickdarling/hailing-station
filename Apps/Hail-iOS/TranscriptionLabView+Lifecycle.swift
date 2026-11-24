import Foundation
import HailCore
extension TranscriptionLabView {
    @MainActor
    func begin() async {
        guard !isRecording, !isStarting, !isFinalizing, !isInterrupting,
              finishTask == nil, interruptTask == nil, pendingSendID == nil else { return }
        guard !Task.isCancelled, scenePhase == .active,
              talkSession.admit(captureOwnerID, receive: receiveResult, cleanup: { await self.finish(force: true) })
        else { startTask = nil; return }
        recordingDestination = boundDestination
        recordingGeneration = destinationGeneration
        takeCaptureExclusivity()
        isStarting = true
        hasReceivedAudio = false
        finalText = ""
        volatileText = ""
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
            guard scenePhase == .active else { throw CancellationError() }
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
    @MainActor
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
    @MainActor
    func finish(force: Bool = false) async {
        guard talkSession.owner == captureOwnerID else { return }
        defer { retireTalkIfIdle() }
        // Never takes suppression (#760): with a finish pending and no hold, the capture is already stopped.
        if force { isForcedTeardown = true }
        if let pendingFinish = finishTask {
            if force {
                let generation = UUID()
                let task = Task {
                    await audioSession.deactivate()
                    await pendingFinish.value
                }
                finishGeneration = generation
                finishTask = task
                await task.value
                completeFinish(generation: generation)
            } else if let generation = finishGeneration {
                await pendingFinish.value
                completeFinish(generation: generation)
            }
            return
        }
        let generation = UUID()
        let task = Task { await performFinish(force: force) }
        finishGeneration = generation
        finishTask = task
        await task.value
        completeFinish(generation: generation)
    }
    @MainActor
    private func performFinish(force: Bool) async {
        if force, await prepareForcedFinish() { return }
        if force, pendingSendID != nil, !isRecording, bufferTask == nil, activeUtteranceID == nil {
            await audioSession.deactivate()
            return
        }
        guard !isInterrupting, !isFinalizing, force || isRecording || bufferTask != nil else { return }
        isFinalizing = true
        defer { isFinalizing = false }
        talkStatus = .message("Finalizing…")
        let finalized = await cleanUp()
        guard !force else {
            talkStatus = .ready
            return
        }
        guard !isForcedTeardown else {
            await audioSession.deactivate()
            talkStatus = .ready
            return
        }
        releaseCaptureExclusivityAfterWork()
        let text = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            talkStatus = .message("Nothing heard")
            return
        }
        finalText = text
        volatileText = ""
        guard onFinalized != nil else {
            talkStatus = .ready
            return
        }
        guard recordingGeneration == destinationGeneration, let recordingDestination,
              let current = boundDestination, current == recordingDestination else {
            talkStatus = .destinationChanged
            return
        }
        await send(text, failurePrefix: "Send failed")
    }
    private var boundDestination: ConversationDestinationID.Connection? {
        guard let selected = selectedDestination(), selected.id == destinationID else { return nil }
        return selected
    }
    @MainActor
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
    @MainActor
    private func handleStartCancellation() async {
        if isInterrupting {
            await discardCapture()
        } else {
            _ = await cleanUp()
            talkStatus = .ready
        }
        releaseCaptureExclusivityAfterWork()
    }
    @MainActor
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
