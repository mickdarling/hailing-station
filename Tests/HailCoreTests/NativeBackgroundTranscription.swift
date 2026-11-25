#if os(macOS)
import SwiftUI
import Testing
@testable import HailCore

extension EnvironmentValues {
    @Entry var onNativeTalkMount: (@MainActor (StationTalkSession) -> Void)?
}

/// NativeSceneTestSupport replaces the button chrome. Its appearance gives the fixture the installed @State.
struct NativeTranscriptionMount: View {
    let view: StationTranscriptionView
    @Environment(NativeSceneAmbientProbe.self) private var probe: NativeSceneAmbientProbe?
    @Environment(\.onNativeTalkMount) private var onMount

    var body: some View {
        Text(String(describing: type(of: view.capture)))
            .onAppear {
                probe?.transcription?.mounted = view
                onMount?(view.talkSession)
            }
            .onDisappear { probe?.transcription?.didDisappear() }
    }
}

@MainActor
final class NativeBackgroundTranscription {
    enum Surface: CaseIterable, Sendable { case talk, labs }
    let mode: Surface
    let tap = FakeAudioCapture()
    let speech = FakeTranscriber()
    private lazy var session = StationTalkSession { [tap, speech] in
        TranscriptionResources(capture: tap, transcriber: speech)
    }
    var mounted: StationTranscriptionView?
    private(set) var sends = 0
    private(set) var disappearances = 0

    init(_ mode: Surface) { self.mode = mode }

    func didDisappear() {
        disappearances += 1
        mounted = nil
    }

    @ViewBuilder
    func surface(in root: StationRootView) -> some View {
        switch mode {
        case .talk:
            if let destination = root.destination {
                StationTranscriptionView(audioSession: root.audioRoutes,
                    destinationLabel: destination.label, destinationID: StationConversationDestinationID(
                        endpointID: destination.hostID, targetID: destination.target.id
                    ), onFinalized: { _, _ in self.sends += 1 })
                    .sharingTalkSession(session)
            }
        case .labs:
            StationTranscriptionView(audioSession: root.audioRoutes).sharingTalkSession(session)
        }
    }

    /// Start synthetic input on the mounted surface without requesting microphone or speech permission.
    func start() async throws {
        let view = try #require(mounted)
        #expect((view.onFinalized != nil) == (mode == .talk))
        try await view.audioSession.activate()
        view.activeUtteranceID = await speech.start()
        let buffers = try view.capture.start()
        view.bufferTask = Task {
            for await buffer in buffers { await self.speech.consume(buffer) }
        }
        view.isRecording = true
        try tap.yield(sineBuffer())
        try await waitUntil { await self.speech.consumedBuffers == 1 }
        try #require(view.isRecording && tap.startCount == 1 && tap.stopCount == 0)
    }
}
#endif
