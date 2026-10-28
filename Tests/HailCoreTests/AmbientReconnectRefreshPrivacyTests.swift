import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectRefreshPrivacyTests {
    @Test func pendingRefreshMustPreservePrivacyConfirmedAfterOriginalDrop() async throws {
        let run = try AmbientAcceptanceSettleRun()
        let rig = run.rig
        try await run.start()
        #expect(try await audioFrames(rig.socket).isEmpty == false)
        try await rig.socket.push(.duckMode(on: true, reason: "voice"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.isOn() == true } }
        #expect(rig.controller.reconnect.isPending)
        var refreshed = rig.endpoint
        refreshed.url = try #require(URL(string: "ws://127.0.0.1:18767"))
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: refreshed.url)
        await rig.store.upsert(refreshed)
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        await run.delivery.fire()
        for index in 0..<12 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil {
            try await rig.socket.sentFrames().contains { frame in
                if case .audio = frame.payload { return true }
                return frame.payload == .control(.setPrivacy(on: true))
            }
        }
        let frames = try await rig.socket.sentFrames()
        #expect(frames.contains { $0.payload == .control(.setPrivacy(on: true)) },
                "The refreshed connection lost the privacy-on state confirmed while recovery was pending")
        #expect(try await audioFrames(rig.socket).isEmpty,
                "PCM reached the refreshed connection without privacy reassertion or confirmation")
        await run.delivery.fire()
        await rig.close()
    }

    @Test func confirmedPrivateRequirementSurvivesAnOffNoticeBeforeRefresh() async throws {
        let run = try AmbientAcceptanceSettleRun()
        let rig = run.rig
        try await run.start()
        try await rig.socket.push(.duckMode(on: true, reason: "voice"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.isOn() == true } }
        try await rig.socket.push(.duckMode(on: false, reason: "voice"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.isOn() == false } }
        var refreshed = rig.endpoint
        refreshed.name = "Refreshed synthetic name"
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: refreshed.url)
        await rig.store.upsert(refreshed)
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        try await waitUntil { try await rig.socket.sentFrames().contains {
            $0.payload == .control(.setPrivacy(on: true))
        } }
        await run.delivery.fire()
        for _ in 0..<6 { try rig.capture.yield(sineBuffer()) }
        #expect(try await audioFrames(rig.socket).isEmpty)
        try await rig.socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { rig.controller.binding?.connectionGeneration
            == rig.store.snapshots[rig.endpoint.id]?.connectionGeneration } }
        for _ in 0..<12 { try rig.capture.yield(sineBuffer()) }
        try await waitUntil { try await audioFrames(rig.socket).isEmpty == false }
        try await waitUntil { await run.delivery.isWaiting() }
        await run.delivery.fire()
        await rig.close()
    }
}
