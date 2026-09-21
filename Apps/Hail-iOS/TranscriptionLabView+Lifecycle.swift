import AVFAudio
import Speech

@available(iOS 26.0, *)
extension TranscriptionLabView {
    @MainActor
    func begin() async {
        guard !isRecording, !isStarting, !isFinalizing else { return }
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
            try await transcriber.start()
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
            _ = await cleanUp()
            status = "Ready"
        } catch {
            _ = await cleanUp()
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    @MainActor
    func finish(force: Bool = false) async {
        guard !isFinalizing, force || isRecording || bufferTask != nil else { return }
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
    private func fail(_ message: String) async {
        _ = await cleanUp(waitForBuffer: false)
        status = message
    }

    @MainActor
    private func cleanUp(waitForBuffer: Bool = true) async -> String {
        capture.stop()
        let task = bufferTask
        bufferTask = nil
        if waitForBuffer { await task?.value }
        let finalized = await transcriber.stop()
        await audioSession.deactivate()
        isRecording = false
        return finalized
    }

    @MainActor
    func observeResults() async {
        for await result in transcriber.results {
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
