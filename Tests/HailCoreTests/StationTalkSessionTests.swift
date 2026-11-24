import Foundation
import Synchronization
import Testing
@testable import HailCore

@MainActor
struct StationTalkSessionTests {
    @Test(arguments: [false, true])
    func stationFinalizesBeforeLabsCanStart(explicitFinish: Bool) async {
        let rig = TalkWindowFixture()
        await rig.station.begin()
        rig.speech.holdNextStop = true
        let finishing = Task { await rig.station.finish(force: !explicitFinish) }
        await rig.speech.stopping.wait()
        await rig.labs.begin()
        #expect(!rig.labs.isRecording && rig.speech.starts == 1)
        #expect(rig.session.owner == rig.station.captureOwnerID)

        await rig.speech.finishStop.release()
        await finishing.value
        #expect(rig.station.sent == (explicitFinish ? [rig.speech.text] : []))
        await rig.labs.begin()
        #expect(rig.labs.isRecording && rig.session.owner == rig.labs.captureOwnerID)
        #expect(rig.capture.startCount == 2 && rig.speech.subscriptions.withLock { $0 } == 1)
        await rig.labs.finish()
        #expect(rig.labs.finalText == rig.speech.text && rig.labs.sent.isEmpty)
    }

    @Test func closingLabsFinishesItsOwnCaptureBeforeStationResumes() async {
        let rig = TalkWindowFixture()
        await rig.labs.begin()
        await rig.station.finish(force: true)
        var escapes = 0
        await rig.station.interruptTarget { escapes += 1 }
        #expect(escapes == 1 && rig.capture.stopCount == 0)
        #expect(!rig.station.audioSession.deactivating && rig.labs.isRecording)

        rig.speech.holdNextStop = true
        let closing = Task { await rig.labs.finish(force: true) }
        await rig.speech.stopping.wait()
        await rig.station.begin()
        #expect(rig.session.owner == rig.labs.captureOwnerID && rig.speech.starts == 1)
        await rig.speech.finishStop.release()
        await closing.value
        #expect(rig.labs.audioSession.deactivating && rig.labs.sent.isEmpty)
        await rig.station.begin()
        #expect(rig.station.isRecording && rig.speech.starts == 2)
        await rig.station.finish()
        #expect(rig.station.sent == [rig.speech.text])
    }

    @Test func olderRegistrationExitsAfterLabsRegistersThenSceneGoesInactive() async throws {
        let rig = TalkWindowFixture()
        await rig.station.begin()
        await rig.station.finish(force: true)
        await rig.labs.begin()
        let labsID = try #require(rig.labs.activeUtteranceID)

        let result = TranscriptionResult(utteranceID: labsID, text: "local caption", isFinal: false)
        let captions = AsyncStream<TranscriptionResult>.makeStream()
        rig.labs.onResult = { captions.continuation.yield($0) }
        rig.speech.publish(result)
        var iterator = captions.stream.makeAsyncIterator()
        let caption = await iterator.next()
        #expect(caption == result && rig.station.received.isEmpty)

        rig.session.retire(rig.station.captureOwnerID) // The older presentation's deferred removal.
        #expect(rig.session.owner == rig.labs.captureOwnerID)
        let routes = AudioRouteModel(controller: ManagedAudioSession(backend: FakeAudioSessionBackend(inputs: [])))
        try await routes.activate()
        await rig.session.cleanUpScene {
            #expect(!rig.labs.isRecording && rig.session.owner == nil)
            await rig.station.begin() // Admission stays closed through route deactivation.
            #expect(!rig.station.isRecording)
            await routes.sceneBecameInactive()
        }
        #expect(!routes.diagnostics.isActive && rig.labs.audioSession.deactivating)
        #expect(rig.speech.stops == 2 && rig.labs.sent.isEmpty)
    }

    @Test func interruptKeepsOwnershipUntilTheInFlightConsumerExits() async throws {
        let rig = TalkWindowFixture()
        await rig.station.begin()
        try rig.capture.yield(sineBuffer())
        await rig.speech.consuming.wait()
        let interrupt = Task { await rig.station.interruptTarget(using: {}) }
        await rig.speech.cancelled.wait()
        await rig.labs.begin()
        #expect(rig.station.bufferTask != nil && rig.session.owner == rig.station.captureOwnerID)
        #expect(!rig.labs.isRecording && rig.speech.starts == 1)
        await rig.speech.finishConsume.release()
        await interrupt.value
        await rig.labs.begin()
        #expect(rig.speech.consumed && rig.station.bufferTask == nil)
        #expect(rig.labs.isRecording && rig.speech.starts == 2 && rig.station.sent.isEmpty)
        await rig.labs.finish(force: true)
    }

    @Test func routeModelHasNoTalkResourceAccessorOrMutableObserverSlot() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Apps/Hail-iOS")
        let routes = try String(contentsOf: app.appendingPathComponent("AudioRouteModel.swift"), encoding: .utf8)
        var lexer = StopReferenceLexer(routes)
        let tokens = Set(try lexer.tokens())
        #expect(tokens.isDisjoint(with: ["StationTalkSession", "TranscriptionResources", "AudioCapturing",
                                         "Transcriber", "capture", "transcriber", "shellTalk", "resources",
                                         "installSceneCleanup", "removeSceneCleanup"]))
        let root = try String(contentsOf: app.appendingPathComponent("RootView.swift"), encoding: .utf8)
        #expect(root.contains("stationRoot.sharingTalkSession(talkSession)"))
        #expect(root.contains("talkSession.cleanUpScene { await audioRoutes.sceneBecameInactive() }"))
    }
}

@MainActor
private struct TalkWindowFixture {
    let capture = FakeAudioCapture()
    let speech = WindowTranscriber()
    let session: StationTalkSession
    let station: TranscriptionLabView
    let labs: TranscriptionLabView

    init() {
        let session = StationTalkSession { [capture, speech] in
            TranscriptionResources(capture: capture, transcriber: speech)
        }
        self.session = session
        let playback = ReplyPlaybackController(player: DuplexPlayer())
        playback.captureLivenessSleep = { _ in throw CancellationError() }
        station = TranscriptionLabView(talkSession: session, playback: playback)
        labs = TranscriptionLabView(talkSession: session, playback: playback)
        station.onFinalized = { _ in }
    }
}

@MainActor
private final class WindowTranscriber: Transcriber {
    nonisolated let subscriptions = Mutex(0)
    private nonisolated let output = AsyncStream<TranscriptionResult>.makeStream()
    nonisolated var results: AsyncStream<TranscriptionResult> {
        subscriptions.withLock { $0 += 1 }
        return output.stream
    }
    let text = "fixture final"
    let consuming = OpenGate(), finishConsume = OpenGate(), cancelled = OpenGate()
    let stopping = OpenGate(), finishStop = OpenGate()
    var starts = 0, stops = 0
    var consumed = false
    var holdNextStop = false

    func start() async throws -> UUID {
        starts += 1
        return UUID()
    }
    func consume(_ buffer: AudioCaptureBuffer) async throws {
        await consuming.release()
        await finishConsume.wait()
        consumed = true
    }
    func stop() async -> String {
        stops += 1
        if holdNextStop {
            holdNextStop = false
            await stopping.release()
            await finishStop.wait()
        }
        return text
    }
    func cancel() async { await cancelled.release() }
    func publish(_ result: TranscriptionResult) { output.continuation.yield(result) }
}
