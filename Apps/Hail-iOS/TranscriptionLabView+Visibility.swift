#if os(macOS)
import AppKit
#endif
import HailCore
import SwiftUI

extension StationTranscriptionView {
    /// The station owns the shared audio route. Losing visibility only discards this view's microphone capture.
    func stopCaptureWhenHidden() {
        guard isRecording || startTask != nil, finishTask == nil, interruptTask == nil else { return }
        let pendingStart = startTask
        pendingStart?.cancel()
        isForcedTeardown = true
        let generation = UUID()
        finishGeneration = generation
        finishTask = Task {
            await pendingStart?.value
            let consumer = bufferTask
            await discardCapture()
            await consumer?.value
            status = "Ready"
            completeFinish(generation: generation)
        }
    }

    @MainActor
    func discardCapture() async {
        capture.stop()
        bufferTask?.cancel()
        bufferTask = nil
        activeUtteranceID = nil
        await transcriber.cancel()
        isRecording = false
    }
}

extension View {
    @ViewBuilder
    func onTranscriptionWindowHidden(_ action: @escaping @MainActor () -> Void) -> some View {
        #if os(macOS)
        background(TranscriptionWindowObserver(onHidden: action))
        #else
        self
        #endif
    }
}

#if os(macOS)
/// AppKit reports occlusion per window, even when SwiftUI keeps the scene active and the view mounted.
private struct TranscriptionWindowObserver: NSViewRepresentable {
    let onHidden: @MainActor () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.onHidden = onHidden }

    final class ObserverView: NSView {
        var onHidden: (@MainActor () -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            let name = NSWindow.didChangeOcclusionStateNotification
            NotificationCenter.default.removeObserver(self, name: name, object: window)
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                       name: name, object: newWindow)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func occlusionChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  !window.isVisible || !window.occlusionState.contains(.visible) else { return }
            onHidden?()
        }
    }
}
#endif
