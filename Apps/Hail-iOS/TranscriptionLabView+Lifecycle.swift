import AVFAudio
import HailCore
import Speech
extension TranscriptionLabView {
    @MainActor
    func begin() async {
        guard !isRecording, !isStarting, !isFinalizing, !isInterrupting,
              finishTask == nil, interruptTask == nil, pendingSendID == nil else { return }
        takeCaptureExclusivity()
        isStarting = true
        hasReceivedAudio = false
        (finalText, volatileText) = ("", "")
        defer {
            isStarting = false
            startTask = nil
            restorePlaybackIfRequestedAndReady()
        }
        guard await prepareCaptureAuthorization() else { return }
        do {
            try await quietReplyAudio()
            try Task.checkCancellation()
            status = "Preparing on-device speech model…"
            try await audioSession.activate()
            let utteranceID = try await transcriber.start()
            activeUtteranceID = utteranceID
            try Task.checkCancellation()
            let buffers = try capture.start()
            isRecording = true
            status = "Listening"
            bufferTask = Task { await consumeCapture(buffers, utteranceID: utteranceID) }
        } catch is CancellationError {
            await handleStartCancellation()
        } catch {
            _ = await cleanUp()
            releaseCaptureExclusivityAfterWork()
            status = "Could not start: \(error.localizedDescription)"
        }
    }
    @MainActor
    private func consumeCapture(_ buffers: AsyncStream<AudioCaptureBuffer>, utteranceID: UUID) async {
        guard activeUtteranceID == utteranceID else { return }
        var failure: String?
        do {
            try await CapturePlaybackSuppression.consume(buffers, owner: captureOwnerID, transitioning: { [self] in
                isStarting || isFinalizing || isInterrupting || startTask != nil || finishTask != nil
            }, receive: {
                markAudioReceived()
                try await transcriber.consume($0)
            })
        } catch { failure = "Capture failed: \(error.localizedDescription)" }
        // finish/interrupt already own cleanup and can be awaiting this task. Never await ourselves or send a
        // partial request merely because the microphone ended. Unowned normal, failed and cancelled ends clean up.
        // A late cancelled consumer must not tear down a replacement capture on this same view.
        guard activeUtteranceID == utteranceID, bufferTask != nil,
              !isFinalizing, !isInterrupting, !isForcedTeardown else { return }
        await fail(failure ?? "Capture ended — tap to talk again")
    }
    @MainActor
    func finish(force: Bool = false) async {
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
        status = "Finalizing…"
        let destinationGenerationAtStart = destinationGeneration
        let finalized = await cleanUp()
        guard !force else {
            status = "Ready"
            return
        }
        guard !isForcedTeardown else {
            await audioSession.deactivate()
            status = "Ready"
            return
        }
        releaseCaptureExclusivityAfterWork()
        let text = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status = "Nothing heard"
            return
        }
        finalText = text
        volatileText = ""
        if onFinalized != nil {
            guard destinationGeneration == destinationGenerationAtStart else {
                status = "Destination changed — request not sent"
                return
            }
            await send(text, failurePrefix: "Send failed")
        } else {
            status = "Ready"
        }
    }
    @MainActor
    func interruptTarget(using action: @MainActor () async throws -> Void) async {
        guard !isInterrupting else { return }
        if let pendingDestinationID { Self.uncorrelatedDestinations.insert(pendingDestinationID) }
        clearPendingSend()
        isInterrupting = true
        defer {
            isInterrupting = false
            restorePlaybackIfRequestedAndReady()
        }
        let discardedUtterance = isStarting || isRecording || bufferTask != nil || activeUtteranceID != nil
        let pendingStart = startTask
        pendingStart?.cancel()
        capture.stop()
        bufferTask?.cancel()
        bufferTask = nil
        isRecording = false
        activeUtteranceID = nil
        if discardedUtterance {
            (finalText, volatileText) = ("", "")
        }
        do {
            try await action()
            status = "Escape sent"
        } catch {
            status = "Escape failed: \(error.localizedDescription)"
        }
        if discardedUtterance {
            await transcriber.cancel()
        }
        await pendingStart?.value
        releaseCaptureExclusivityAfterWork()
    }
    @MainActor
    private func fail(_ message: String) async {
        _ = await cleanUp(waitForBuffer: false)
        releaseCaptureExclusivityAfterWork()
        status = message
    }
    @MainActor
    private func handleStartCancellation() async {
        if isInterrupting {
            await discardCapture()
        } else {
            _ = await cleanUp()
            status = "Ready"
        }
        releaseCaptureExclusivityAfterWork()
    }
    @MainActor
    private func cleanUp(waitForBuffer: Bool = true) async -> String {
        capture.stop()
        let task = bufferTask
        bufferTask = nil
        if waitForBuffer { await task?.value }
        defer { (activeUtteranceID, isRecording) = (nil, false) }
        return await transcriber.stop()
    }
    @MainActor
    func noteDestinationChange(
        previous: ConversationDestinationID?, current: ConversationDestinationID?
    ) {
        guard current != previous else { return }
        destinationGeneration = UUID()
        let invalidatedSend = pendingSendID != nil
        if let pendingDestinationID { Self.uncorrelatedDestinations.insert(pendingDestinationID) }
        clearPendingSend()
        if invalidatedSend {
            status = "Ready"
            return
        }
        guard !isStarting, !isRecording, !isFinalizing, !isInterrupting else { return }
        status = "Ready"
    }
}
