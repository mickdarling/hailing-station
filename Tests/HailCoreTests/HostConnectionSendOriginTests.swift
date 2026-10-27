import Foundation
import HailProtocol
import Testing
@testable import HailCore

@Suite struct HostConnectionSendOriginTests {
    @Test func defaultSendAudioPreservesEveryWireFieldAndSequence() async throws {
        let rig = try await SendOriginRig.ready()
        let stream = UUID()
        let payloads = [0, 2, 3].map { ambientSegment(stream: stream, sequence: $0) }
        for payload in payloads { try await rig.connection.sendAudio(payload) }
        let frames = try await audioFrames(rig.socket)
        #expect(frames.count == payloads.count)
        for (frame, payload) in zip(frames, payloads) {
            // IDs remain fresh per frame. All encoded fields have the same values as the pre-R0 path.
            let expected = Frame(id: frame.id, timestamp: 42, target: ambientTarget,
                                 source: "Synthetic", payload: .audio(payload))
            #expect(try FrameCoding.encode(frame) == FrameCoding.encode(expected))
        }
        await rig.connection.disconnect()
    }

    @Test func defaultObserverPreservesNoticeEventsAndOrderWithOrigin() async throws {
        let rig = try await SendOriginRig.ready()
        let controls: [ControlPayload] = [
            .duckMode(on: true, reason: "device"), .mediaMode(on: true, reason: "voice"),
            .ownerVoice(state: "unrecognized"), .duckMode(on: false, reason: "device")
        ]
        for control in controls { try await rig.process(control) }
        let events = await rig.recorder.events
        #expect(events.map(\.frame.payload) == controls.map { .control($0) })
        #expect(events.allSatisfy { $0.endpointID == "mac-1" && $0.frame.source == "Synthetic" })
        let generation = await rig.connection.currentSnapshot().connectionGeneration
        #expect(await rig.recorder.origins == Array(repeating: generation, count: controls.count))
        #expect(await rig.recorder.streams.allSatisfy { $0 == nil })
        #expect(HostNoticeOrigin.generation == nil)
        await rig.connection.disconnect()
    }

    @Test func defaultAmbientRefusalPublishesNothingAndPreservesStreamFailure() async throws {
        let rig = try await SendOriginRig.ready()
        let stream = UUID()
        try await rig.connection.sendAudio(ambientSegment(stream: stream))
        try await rig.process(.error(code: .notAllowed, message: "ambient busy"))
        #expect(await rig.recorder.events.isEmpty)
        #expect(await rig.connection.currentSnapshot().state == .ready)
        await #expect(throws: HostConnectionFailure.remote("not_allowed: ambient busy")) {
            try await rig.connection.sendAudio(ambientSegment(stream: stream, sequence: 1))
        }
        try await rig.connection.sendAudio(ambientSegment())
        #expect(try await audioFrames(rig.socket).count == 2)
        await rig.connection.disconnect()
    }

    @Test func optedInRefusalCarriesReceivingOriginAndRefusedStream() async throws {
        let rig = try await SendOriginRig.ready(reportRefusals: true)
        let stream = UUID()
        try await rig.connection.sendAudio(ambientSegment(stream: stream))
        try await rig.socket.push(.error(code: .notAllowed, message: "ambient busy"))
        try await waitUntil { await rig.recorder.events.count == 1 }
        #expect(await rig.recorder.streams == [stream])
        #expect(await rig.recorder.origins == [rig.connection.currentSnapshot().connectionGeneration])
        await rig.connection.disconnect()
    }

    @Test func mismatchedGenerationThrowsWithoutSendingAndMatchingGenerationSends() async throws {
        let (connection, socket) = try await readyAudioConnection(capabilities: ["select_target", "stream_audio"])
        await #expect(throws: HostConnectionFailure.notReady) {
            try await connection.sendAudio(ambientSegment(), bindingGeneration: UUID())
        }
        #expect(try await audioFrames(socket).isEmpty)
        let generation = await connection.currentSnapshot().connectionGeneration
        try await connection.sendAudio(ambientSegment(), bindingGeneration: generation)
        #expect(try await audioFrames(socket).count == 1)
        await connection.disconnect()
    }
}
