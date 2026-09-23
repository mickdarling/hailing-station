import AVFAudio
import Speech
extension TranscriptionLabView {
    @MainActor
    func begin() async {
        guard !isRecording, !isStarting, !isFinalizing, !isInterrupting else { return }
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
            let pendingStart = startTask
            pendingStart?.cancel()
            await audioSession.deactivate()
            await pendingStart?.value
        }
        if let pendingFinish = finishTask {
            await pendingFinish.value
            finishTask = nil
            restorePlaybackIfRequestedAndReady()
            return
        }
        let task = Task { await performFinish(force: force) }
        finishTask = task
        await task.value
        finishTask = nil
        restorePlaybackIfRequestedAndReady()
    }

    @MainActor
    private func performFinish(force: Bool) async {
        if force, isInterrupting { return }
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
        if let onFinalized {
            status = "Sending…"
            do {
                try await onFinalized(text)
                status = "Sent"
            } catch {
                status = "Send failed: \(error.localizedDescription)"
            }
        } else {
            status = "Ready"
        }
    }

    @MainActor
    func interruptTarget(using action: @MainActor () async throws -> Void) async {
        guard !isInterrupting else { return }
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

    @MainActor
    func observeResults() async {
        let coordinator = audioSession as? any AudioSceneCleanupCoordinating
        coordinator?.installSceneCleanup { await finish(force: true) }
        defer { coordinator?.removeSceneCleanup() }
        for await result in transcriber.results {
            guard result.utteranceID == activeUtteranceID else { continue }
            if result.isFinal {
                appendFinal(result.text)
                volatileText = ""
            } else {
                volatileText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    private func appendFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finalText = [finalText, trimmed].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func markAudioReceived() {
        guard !hasReceivedAudio else { return }
        hasReceivedAudio = true
        status = "Receiving audio"
    }
}
