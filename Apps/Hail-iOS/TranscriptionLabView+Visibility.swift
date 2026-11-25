#if os(macOS)
import AppKit
#endif
import HailCore
import SwiftUI

// Window injection is shared by Station and Labs. Only the Talk surface reads the private key.
private extension EnvironmentValues {
    @Entry var windowTalkSession: StationTalkSession?
}

extension View {
    func sharingTalkSession(_ session: StationTalkSession) -> some View {
        environment(\.windowTalkSession, session)
    }
}

extension StationTranscriptionView {
    @propertyWrapper
    struct WindowTalk: DynamicProperty {
        @Environment(\.windowTalkSession) private var session

        var wrappedValue: StationTalkSession {
            guard let session else { preconditionFailure("Talk requires its window’s session") }
            return session
        }
    }

    var talkButton: some View { StationTalkButton(station: self) }

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
            // Retire only the start this hide cancelled.
            if let pendingStart, startTask == pendingStart { startTask = nil }
            let consumer = bufferTask
            // A cancelled start cleans up before returning. Only a recording still owns resources to discard.
            if isRecording { await discardCapture() }
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

/// Both the rendered button and its queued start read the current scene and window.
@MainActor @Observable
private final class TalkVisibility {
    var sceneIsActive = false
    #if os(macOS)
    var windowIsVisible = false
    #endif

    var allowsStart: Bool {
        #if os(macOS)
        sceneIsActive && windowIsVisible
        #else
        sceneIsActive
        #endif
    }
}

private struct StationTalkButton: View {
    let station: StationTranscriptionView
    @Environment(\.scenePhase) private var scenePhase
    @State private var visibility = TalkVisibility()

    var body: some View {
        station.makeTalkButton(whenVisible: { [visibility] in visibility.allowsStart })
            #if os(macOS)
            .background(TranscriptionWindowObserver(visibility: visibility,
                                                    onHidden: station.stopCaptureWhenHidden))
            #endif
            .onChange(of: scenePhase, initial: true) { _, phase in
                visibility.sceneIsActive = phase == .active
                if phase == .background { station.stopCaptureWhenHidden() }
            }
    }
}

#if os(macOS)
/// AppKit reports occlusion per window, even when SwiftUI keeps the scene active and the view mounted.
private struct TranscriptionWindowObserver: NSViewRepresentable {
    let visibility: TalkVisibility
    let onHidden: @MainActor () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.visibility = visibility
        view.onHidden = onHidden
    }

    final class ObserverView: NSView {
        var visibility: TalkVisibility?
        var onHidden: (@MainActor () -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            let name = NSWindow.didChangeOcclusionStateNotification
            NotificationCenter.default.removeObserver(self, name: name, object: window)
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                       name: name, object: newWindow)
            }
            updateVisibility(of: newWindow)
            super.viewWillMove(toWindow: newWindow)
        }

        @discardableResult private func updateVisibility(of window: NSWindow?) -> Bool {
            let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            visibility?.windowIsVisible = visible
            return visible
        }

        @objc private func occlusionChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            if !updateVisibility(of: window) { onHidden?() }
        }
    }
}
#endif
