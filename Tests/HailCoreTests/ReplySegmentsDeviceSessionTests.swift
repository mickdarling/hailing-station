import Foundation
import HailProtocol
import Testing
@testable import HailCore

@Suite struct ReplySegmentsDeviceSessionTests {
    @MainActor @Test func deviceHoldsFramesAfterSegmentEndUntilPlaybackCompletes() throws {
        let player = SegmentsReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let stream = UUID()
        let reply = ReplyDescriptor(id: UUID(), hostID: "host", targetID: "target", audioStreamID: stream)
        for sequence in 0...1 {
            let audio = AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
                                     streamID: stream, isFinal: sequence == 1, bytes: Data([1, 0]), reply: reply,
                                     isSegmentEnd: sequence == 0)
            let frame = Frame(timestamp: Int64(sequence), target: "target", source: "host", payload: .audio(audio))
            let decoded = try FrameCoding.decode(FrameCoding.encode(frame))
            controller.ingest(HostReplyEvent(endpointID: "synthetic", frame: decoded))
        }
        #expect(player.scheduled.map(\.sequence) == [0])
        #expect(player.completions == 1) // Segment completion starts the pause; final has not been scheduled.
        #expect(player.pauses == 0)
        #expect(!controller.isPaused)
    }

    @Test func deviceAdvertisesSegmentsAndStillRefusesReplyYieldFromHost() async throws {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let connection = HostConnection(endpoint: endpoint, connector: connector)
        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        guard case .control(.hello(let hello))? = try await socket.sentFrames().first?.payload else {
            Issue.record("expected device hello")
            return
        }
        #expect(hello.capabilities.contains(ReplySegments.capability))
        #expect(hello.capabilities.contains(HeardTurns.capability))
        try await socket.push(hostHello())
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        try await socket.push(.replyYield(reply: UUID(), segment: 1))
        try await waitUntil {
            if case .failed = await connection.currentSnapshot().state { return true }
            return false
        }
        #expect(await connection.currentSnapshot().state
            == .failed(reason: "unexpected control frame"))
        #expect(await socket.closeCount == 1)
        await connection.disconnect()
    }
}

@MainActor private final class SegmentsReplyPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var completions = 0
    var pauses = 0
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
        if onPlayed != nil { completions += 1 }
    }
    func cancel() {}
    func pause() { pauses += 1 }
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}

@MainActor @Suite struct ReplySegmentDeviceWiringTests {
    @Test(arguments: ["capable", "older", "negotiating", "disconnected"])
    func onsetStopsLocallyAndSendsOnlyToItsReadyCapableEndpoint(_ state: String) async throws {
        let fixture = SegmentWireFixture()
        let socket = try await fixture.connect("main", ready: state != "negotiating", capable: state != "older")
        let other = try await fixture.connect("other")
        if state == "disconnected" { await fixture.store.disconnect("main") }
        try await fixture.open(played: 2)
        fixture.controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 9, endpoint: "other"))
        try await fixture.detect()
        #expect(fixture.controller.lastSegmentYield?.replyID == fixture.reply.id)
        #expect(fixture.controller.lastSegmentYield?.segment == 2)
        #expect(fixture.player.cancelCount == 1)
        #expect(fixture.controller.activeKey?.endpointID == "other")
        if state == "capable" {
            try await waitUntil { try await socket.sentFrames().contains { $0.isSegmentYield } }
        }
        // Await a further actor turn after the asynchronous send attempt.
        await fixture.store.sendReplyYield(
            .init(endpointID: "missing", replyID: UUID(), segment: 1), connectionGeneration: UUID()
        )
        let sent = try await socket.sentFrames().filter(\.isSegmentYield)
        #expect(sent.count == (state == "capable" ? 1 : 0))
        if let first = sent.first {
            #expect(first.payload == .control(.replyYield(reply: fixture.reply.id, segment: 2)))
        }
        #expect(try await other.sentFrames().filter(\.isSegmentYield).isEmpty)
        fixture.controller.ingest(idleAudio(fixture.reply, sequence: 8, final: true, byte: 5))
        #expect(fixture.player.scheduled.last?.bytes.first == 9)
        await fixture.cleanup()
    }

    @Test(arguments: [false, true])
    func onsetRechecksFreshAuthorizationAfterCaptureRead(_ privacy: Bool) async throws {
        let fixture = SegmentWireFixture()
        let socket = try await fixture.connect("main")
        try await fixture.open()
        try await fixture.calibrate()
        try await fixture.feed(-20, seconds: 0.3) {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    if privacy { fixture.privacy = true } else { fixture.ambient = false }
                }
            }
        }
        #expect(fixture.guarder.segmentOnsetGate.diagnostics.onsets == 1) // Signal reached the fresh-state check.
        #expect(fixture.controller.lastSegmentYield == nil)
        #expect(fixture.player.cancelCount == 0)
        #expect(fixture.controller.segmentPause != nil)
        #expect(try await socket.sentFrames().filter(\.isSegmentYield).isEmpty)
        await fixture.cleanup()
    }

    @Test func closedWindowRejectsAnOldOnsetAndClosesAnalysisWithoutMorePCM() async throws {
        let fixture = SegmentWireFixture()
        try await fixture.open()
        try await fixture.calibrate()
        fixture.controller.stopPlayback(from: "main")
        fixture.store.segmentWiring?.onset()
        #expect(fixture.store.segmentWiring?.captureInput().window == nil)
        #expect(fixture.controller.lastSegmentYield == nil)
        #expect(!fixture.guarder.endReplyTailForYield())
    }

    @Test(arguments: ["same", "other", "late"])
    func ambientHeardFeedsOnlyTheYieldedEndpointsFiveSecondCounter(_ source: String) async throws {
        let fixture = SegmentWireFixture()
        let main = try await fixture.connect("main")
        let other = try await fixture.connect("other")
        try await fixture.open()
        try await fixture.detect()
        let before = fixture.guarder.segmentOnsetGate.diagnostics
        #expect(before.onsets == 1)
        #expect(before.withoutAdmittedRequest == 0)
        fixture.clock.advance(by: source == "late" ? .seconds(5) : .seconds(4))
        let entryCount = fixture.store.conversation.entries.count
        try await (source == "other" ? other : main).push(
            .ambientHeard(targetID: "target", text: "Synthetic request", turn: nil)
        )
        try await waitUntil { @MainActor in fixture.store.conversation.entries.count > entryCount }
        fixture.clock.advance(by: .seconds(1))
        #expect(fixture.guarder.segmentOnsetGate.diagnostics.withoutAdmittedRequest == (source == "same" ? 0 : 1))
        await fixture.cleanup()
    }

    @Test func reconnectGenerationCannotReceiveAnEarlierYield() async throws {
        let fixture = SegmentWireFixture()
        let socket = try await fixture.connect("main")
        let old = try #require(fixture.store.snapshots["main"]?.connectionGeneration)
        let yield = ReplySegmentPause(endpointID: "main", replyID: UUID(), segment: 1)
        #expect(!(await fixture.store.sendReplyYield(yield, connectionGeneration: UUID())))
        #expect(try await socket.sentFrames().filter(\.isSegmentYield).isEmpty)
        #expect(await fixture.store.sendReplyYield(yield, connectionGeneration: old))
        await fixture.cleanup()
    }
}

private extension Frame {
    var isSegmentYield: Bool {
        if case .control(.replyYield) = payload { return true }
        return false
    }
}
