#if os(macOS)
import HailProtocol
import SwiftUI
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct NativeVoicesSettingsTests {
    @Test(arguments: [ReplySegmentSettings(), ReplySegmentSettings(
        pauseAfterSegment: 2.5, sustainedOnset: 0.05, onsetThresholdDBFS: -32.5
    )])
    func mountingUpdatingAndLeavingDoNotControlPlaybackOrSavePreferences(settings: ReplySegmentSettings) async throws {
        let player = VoicesSettingsPlayerSpy()
        let playback = ReplyPlaybackController(player: player)
        playback.segmentSettings = settings
        let persistedBefore = ReplySegmentSettings.saved()
        let generation = playback.playbackGeneration
        let status = playback.status
        let page = VoicesSettingsOverview(playback: playback) { Text("Existing Turn-taking tool") }
        #expect(page.playback === playback)
        let host = NativeStationToolHost(page)
        defer { host.finish() }
        try await host.appeared()
        await host.render()
        #expect(playback.segmentSettings == settings)
        let updated = ReplySegmentSettings(pauseAfterSegment: 4, sustainedOnset: 0.7, onsetThresholdDBFS: -45)
        playback.segmentSettings = updated // An existing owner/tool changes the same observed reference.
        await host.render()
        host.push()
        await host.render()
        #expect(playback.segmentSettings == updated)
        #expect(playback.playbackGeneration == generation && playback.status == status)
        #expect(playback.replies.isEmpty && !playback.isPaused && !playback.isMuted && !playback.isCaptureSuppressed)
        #expect(player.calls.isEmpty, "Visiting the page must not schedule, replace, mute, pause or cancel audio")
        #expect(ReplySegmentSettings.saved() == persistedBefore, "Observation must not save the in-memory settings")
    }
}

/// A controller collaborator without audio hardware. The fixture never schedules a payload.
@MainActor
private final class VoicesSettingsPlayerSpy: ReplyAudioPlaying {
    private(set) var calls: [String] = []

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) { calls.append("schedule") }
    func cancel() { calls.append("cancel") }
    func pause() { calls.append("pause") }
    func resume() { calls.append("resume") }
    func setMuted(_ muted: Bool) { calls.append("mute") }
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {
        calls.append("replace")
    }
}
#endif
