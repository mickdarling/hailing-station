import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectRefreshAdmissionTests {
    @Test func pendingRenewedRefreshDiscardsHeldPCMAndClosesGapAdmission() async throws {
        let encoding = RefreshEncodingGate()
        let run = try AmbientAcceptanceSettleRun(beforeEncode: { await encoding.encode() })
        let rig = run.rig
        try await run.start()
        await encoding.arm()
        try rig.capture.yield(sineBuffer())
        try await waitUntil { await encoding.wait.isWaiting() }
        #expect(rig.controller.reconnect.isPending && rig.controller.isListening)
        let discarded = rig.capture.discardedCount
        var refreshed = rig.endpoint
        refreshed.url = try #require(URL(string: "ws://127.0.0.1:18770"))
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: refreshed.url)
        await rig.store.upsert(refreshed)
        for _ in 0..<6 { try rig.capture.yield(sineBuffer()) }
        #expect(rig.capture.discardedCount == discarded + 6)
        #expect(try await audioFrames(rig.socket).isEmpty)
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        await run.delivery.fire()
        await encoding.release()
        for _ in 0..<12 { try rig.capture.yield(silentBuffer()) }
        try await waitUntil { try await audioFrames(rig.socket).isEmpty == false }
        let frames = try await audioFrames(rig.socket)
        #expect(frames.allSatisfy { frame in
            if case .audio(let audio) = frame.payload { return audio.bytes.allSatisfy { $0 == 0 } }
            return false
        }, "Held or gap PCM crossed the endpoint replacement")
        if case .audio(let audio) = frames.first?.payload { #expect(audio.sequence == 0 && audio.isResume) }
        if case .audio(let audio) = frames.first?.payload, audio.isResume {
            try await waitUntil { await run.delivery.isWaiting() }
        }
        await run.delivery.fire()
        await rig.close()
    }
}

private actor RefreshEncodingGate {
    let wait = SleepGate()
    private var holding = false
    func arm() { holding = true }
    func encode() async { if holding { try? await wait.sleep(.zero) } }
    func release() async { holding = false; await wait.fire() }
}

private func silentBuffer() throws -> AVAudioPCMBuffer {
    let buffer = try sineBuffer()
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(buffer.frameLength) { samples[index] = 0 }
    return buffer
}
