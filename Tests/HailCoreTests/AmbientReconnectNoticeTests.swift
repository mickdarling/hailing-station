import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectNoticeTests {
    @Test(arguments: [true, false])
    func ownerVetoWhileFirstRestoredSendIsHeldCannotPublishSuccess(ownerStop: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        try await rig.select(restoring: true)
        await rig.socket.holdSends()
        for index in 0..<4 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { try await rig.socket.sentFrames().contains { if case .audio = $0.payload {
            return true
        }; return false } }
        let veto = Task {
            if ownerStop {
                await rig.controller.turnOff()
            } else {
                try? await rig.store.setPrivacy(on: true, host: rig.endpoint.id)
            }
        }
        try await waitUntil { await MainActor.run { !rig.controller.isOn } }
        await rig.socket.releaseSends()
        await veto.value
        try await rig.expectStopped(ownerStop ? .ownerStop : .privacy)
        #expect(rig.notices.count == 1)
        await rig.close()
    }
    @Test func longOutageBeforeFirstSendStillRestoresAudio() async throws {
        let rig = try AmbientReconnectRig()
        let clock = TestInstantClock()
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        try await rig.select(restoring: true)
        clock.advance(by: .seconds(60))
        for _ in 0..<4 { try rig.capture.yield(sineBuffer()) }
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.applied])
        #expect(try await !audioFrames(rig.socket).isEmpty)
        #expect(rig.controller.isOn)
        await rig.close()
    }
    @Test(arguments: [AmbientListeningReconnect.Outcome.applied, .blocked, .failed])
    func eachOutcomeInvokesNoticeHookOnceWithContentFreeGapDiagnostics(outcome: AmbientListeningReconnect.Outcome)
    async throws {
        let suite = "hail-904-reconnect-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:])
        log.setEnabled(true)
        let rig = try AmbientReconnectRig()
        rig.controller.diagnostics = log
        try await rig.start()
        try await rig.drop()
        if outcome == .blocked { await rig.controller.turnOff() }
        if outcome == .failed {
            rig.capture.stop()
            try await waitUntil { await MainActor.run { !rig.controller.isOn } }
        }
        if outcome == .applied { try await rig.reconnect() }
        #expect(rig.notices.count == 1 && rig.notices.last?.outcome == outcome)
        let event = try #require(log.nextBatch()?.events.first { $0.name == .captureState })
        #expect(Set(event.fields.keys) == [.state, .on, .error, .code, .ms])
        #expect(event.fields[.on] == .boolean(outcome == .applied))
        if case .integer(let milliseconds) = event.fields[.ms] {
            #expect((0...60_000).contains(milliseconds))
        } else {
            Issue.record("Gap milliseconds missing")
        }
        let encoded = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: encoded) == event)
        await rig.close()
    }
}
