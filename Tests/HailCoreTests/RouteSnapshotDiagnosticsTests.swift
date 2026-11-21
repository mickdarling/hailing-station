import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct RouteSnapshotDiagnosticsTests {
    let suite = "hail-route-snapshot-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }
    let before = AudioRoutePorts(input: .none, output: .none, inputCount: 0, outputCount: 0)
    let speaker = AudioRoutePorts(input: .bluetoothHFP, output: .builtInSpeaker, inputCount: 1, outputCount: 2)
    let applied = AudioRouteSettings(category: .playAndRecord, defaultToSpeaker: true, allowA2DP: true,
                                     allowHFP: false, mixWithOthers: false)

    private func nestedCategoryChange(_ log: DeviceDiagnostics, observations: AudioRouteObservations) {
        // Both consumers can run within setCategory. The notification observer still owns its legacy event.
        #if os(iOS)
        let center = NotificationCenter()
        log.observeSystem(center: center)
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: UInt(3)])
        #else
        log.recordRouteNotification(reason: 3, previous: before)
        #endif
        let change = AudioRouteChange(reasonRaw: 3, current: .init(ports: speaker, settings: applied), previous: before)
        let policy = AudioOutputRoutePolicy.Route(
            outputs: [.speaker], inputs: [.bluetoothHFP], reason: .categoryChange, appInitiatedReconfigure: true
        )
        var state = AudioOutputRoutePolicy.State()
        state.userChoseBuiltIn = true
        let route = ObservedPolicyRoute(policy: policy, change: change)
        AudioOutputRouteDriver.process(
            route, state: &state, observations: observations, observeDecision: { _ in },
            perform: { _ in Issue.record("category notification requested a routing effect") }
        )
    }

    @Test(arguments: [false, true])
    func routeSnapshotAtConfigureChangeAndPlaybackStart(captureOwnsEngine: Bool) throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:], wallNow: { 7 })
        let observations = AudioRouteObservations()
        log.setEnabled(true)
        defaults.set(true, forKey: AudioInputPreferences.bluetoothHFPDefaultsKey)
        observations.setObserving(log, enabled: true)
        var current = DeviceDiagnosticsOutputRouteTests.snapshot(output: .none)
        observations.categoryWrite(before: current.ports, result: current.settings, policyApply: false) {
            current = AudioRouteSnapshot(ports: speaker, settings: applied)
            log.currentAudioRoute = { [current] in current }
            nestedCategoryChange(log, observations: observations)
        }
        // A later owner has different ports and options when the existing playback observer sees busy.
        let keepalive = DeviceDiagnosticsOutputRouteTests.snapshot(output: .bluetoothA2DP)
        let startRoute = captureOwnsEngine ? current : keepalive
        log.currentAudioRoute = { startRoute }
        let player = ObservedReplyPlayer(captureOwnsEngine)
        let playback = ReplyPlaybackController(player: AmbientReplyEchoGuard().guarding(player))
        playback.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 1))
        log.watch(playback)
        let events = try #require(log.nextBatch()).events.filter { $0.fields[.routeSequence] != nil }
        #expect(events.map(\.timestamp) == [7, 7, 7, 7])
        #expect(events.map { $0.fields[.routeSequence] } == [.integer(2), .integer(3), .integer(1), .integer(4)])
        try checkConfigure(events)
        try checkChange(events)
        let start = try #require(events.last)
        #expect(start.name == .replyPlaybackStart)
        #expect(start.fields[.route] == .token(startRoute.ports.output.rawValue))
        #expect(start.fields[.input] == .token(startRoute.ports.input.rawValue))
        #expect(start.fields[.category] == .token(captureOwnsEngine ? "play_and_record" : "playback"))
        #expect(start.fields[.mixWithOthers] == .boolean(!captureOwnsEngine))
        #expect(start.fields[.captureOwnsEngine] == .boolean(captureOwnsEngine))
    }

    private func checkConfigure(_ events: [DiagnosticEvent]) throws {
        let configure = try #require(events.first { $0.fields[.phase] == .token("configure") })
        #expect(configure.fields[.category] == .token("play_and_record"))
        #expect(configure.fields[.output] == nil)
        #expect(configure.fields[.preInput] == .token("none"))
        #expect(configure.fields[.preOutputCount] == .integer(0))
        #expect(configure.fields[.defaultToSpeaker] == .boolean(true))
        #expect(configure.fields[.allowHFP] == .boolean(false))
        #expect(configure.fields[.hfpPreference] == .boolean(true))
        #expect(configure.fields[.policyApply] == .boolean(false))
        #expect(configure.fields[.writeSucceeded] == .boolean(true))
    }

    private func checkChange(_ events: [DiagnosticEvent]) throws {
        let change = try #require(events.first { $0.fields[.decision] != nil })
        #expect(change.fields[.phase] == .token("change"))
        #expect(change.fields[.reason] == .token("category_change"))
        #expect(change.fields[.decision] == .token("no_hardware_episode"))
        #expect(change.fields[.input] == .token("bluetooth_hfp"))
        #expect(change.fields[.route] == change.fields[.input])
        #expect(change.fields[.output] == .token("built_in_speaker"))
        #expect(change.fields[.outputCount] == .integer(2))
        #expect(change.fields[.previousOutput] == .token("none"))
        #expect(change.fields[.userChoseBuiltIn] == .boolean(true))
        #expect(change.fields[.appAttributed] == .boolean(true))
    }

    @Test func sinklessCategoryWriteRunsOnceWithoutReadingDiagnosticProperties() {
        let observations = AudioRouteObservations()
        var writes = 0, reads = 0
        func sample() -> AudioRouteSettings {
            reads += 1
            return applied
        }
        observations.categoryWrite(before: before, result: sample(), policyApply: false) { writes += 1 }
        #expect(writes == 1)
        #expect(reads == 0)
    }

    @Test func failedWriteReportsActualOptionsAndNestedDisableDiscardsTheOldWrite() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults)
        log.setEnabled(true)
        let observations = AudioRouteObservations()
        observations.setObserving(log, enabled: true)
        enum Refusal: Error { case refused }
        do {
            try observations.categoryWrite(before: speaker, result: applied, policyApply: true) {
                throw Refusal.refused
            }
            Issue.record("write error was swallowed")
        } catch Refusal.refused {}
        let event = try #require(log.nextBatch()?.events.last)
        #expect(event.fields[.policyApply] == .boolean(true))
        #expect(event.fields[.writeSucceeded] == .boolean(false))
        #expect(event.fields[.defaultToSpeaker] == .boolean(true))
        observations.categoryWrite(before: speaker, result: applied, policyApply: true) {
            log.setEnabled(false)
            log.setEnabled(true)
        }
        #expect(log.nextBatch()?.events.map(\.name) == [.appInfo])
        #expect(log.beginRouteObservation()?.sequence == 1)
    }
}

@MainActor
private final class ObservedReplyPlayer: ReplyAudioPlaying, CaptureRoutedReplies, PlayoutGapReporting {
    let isRoutedThroughCapture: Bool
    init(_ routed: Bool) { isRoutedThroughCapture = routed }
    func route(through capture: AVAudioEngine?) {}
    func isOnAnotherCapture(than capture: AVAudioEngine) -> Bool { false }
    func captureEngineRestarted(_ capture: AVAudioEngine) {}
    func takePlayoutGaps() -> PlayoutGapMeter.Gaps { .init() }
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
}
