import AVFAudio
import Speech
extension TranscriptionLabView {
    @MainActor
    func begin() async {
        guard !isRecording, !isStarting, !isFinalizing, !isInterrupting,
              finishTask == nil, interruptTask == nil, pendingSendID == nil else { return }
        beginCaptureExclusivity()
        isStarting = true
        hasReceivedAudio = false
        finalText = ""
        volatileText = ""
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
            activeUtteranceID = try await transcriber.start()
            try Task.checkCancellation()
            let buffers = try capture.start()
            isRecording = true
            status = "Listening"
            bufferTask = Task {
                do {
                    for await buffer in buffers {
                        markAudioReceived()
                        try await transcriber.consume(buffer)
                    }
                } catch {
                    await fail("Capture failed: \(error.localizedDescription)")
                }
            }
        } catch is CancellationError {
            await handleStartCancellation()
        } catch {
            _ = await cleanUp()
            releaseCaptureExclusivityAfterWork()
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    @MainActor
    func finish(force: Bool = false) async {
        if force {
            isForcedTeardown = true
            if finishTask != nil, !ownsCaptureSuppression {
                ownsCaptureSuppression = true
                onCaptureWillBegin?(captureOwnerID)
            }
        }
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
        guard !isInterrupting, !isFinalizing, force || isRecording || bufferTask != nil else { return }
        isFinalizing = true
        defer { isFinalizing = false }
        status = "Finalizing…"
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
            await send(text, failurePrefix: "Send failed")
        } else {
            status = "Ready"
        }
    }

    @MainActor
    func interruptTarget(using action: @MainActor () async throws -> Void) async {
        guard !isInterrupting else { return }
        pendingSendID = nil
        pendingDestinationID = nil
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
            finalText = ""
            volatileText = ""
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
        let finalized = await transcriber.stop()
        activeUtteranceID = nil
        isRecording = false
        return finalized
    }
}
