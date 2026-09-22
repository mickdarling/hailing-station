import AVFAudio
import Speech

@available(iOS 26.0, *)
extension TranscriptionLabView {
    @MainActor
    func begin() async {
        guard !isRecording, !isStarting, !isFinalizing, !isInterrupting else { return }
        isStarting = true
        hasReceivedAudio = false
        finalText = ""
        volatileText = ""
        defer {
            isStarting = false
            startTask = nil
        }
        status = "Requesting microphone and speech access…"
        guard await requestHailPermissions() else {
            status = "Microphone and speech recognition permissions are required."
            return
        }

        do {
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
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    @MainActor
    func finish(force: Bool = false) async {
        guard !isInterrupting, !isFinalizing, force || isRecording || bufferTask != nil else { return }
        isFinalizing = true
        defer { isFinalizing = false }
        status = "Finalizing…"
        let finalized = await cleanUp()
        guard !force else {
            status = "Ready"
            return
        }
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
        defer { isInterrupting = false }
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
            await audioSession.deactivate()
        }
        await pendingStart?.value
    }

    @MainActor
    private func fail(_ message: String) async {
        _ = await cleanUp(waitForBuffer: false)
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
    }

    @MainActor
    private func cleanUp(waitForBuffer: Bool = true) async -> String {
        capture.stop()
        let task = bufferTask
        bufferTask = nil
        if waitForBuffer { await task?.value }
        let finalized = await transcriber.stop()
        activeUtteranceID = nil
        await audioSession.deactivate()
        isRecording = false
        return finalized
    }

    @MainActor
    func observeResults() async {
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

    @MainActor
    private func discardCapture() async {
        capture.stop()
        bufferTask?.cancel()
        bufferTask = nil
        activeUtteranceID = nil
        await transcriber.cancel()
        await audioSession.deactivate()
        isRecording = false
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

/// TCC invokes these callbacks on arbitrary queues, so this bridge must not inherit the view's MainActor.
private func requestHailPermissions() async -> Bool {
    let microphone = await withCheckedContinuation(isolation: nil) { continuation in
        AVAudioApplication.requestRecordPermission { @Sendable granted in
            continuation.resume(returning: granted)
        }
    }
    guard microphone else { return false }

    return await withCheckedContinuation(isolation: nil) { continuation in
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            continuation.resume(returning: status == .authorized)
        }
    }
}
