import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// The phone's diagnostics log (#234): off by default and persisted, cleared when turned off, bounded in memory,
/// rate-limited when recording and paced when sending, and unable to hold free text.
@MainActor
@Suite struct DeviceDiagnosticsTests {
    let suite = "hail-device-diagnostics-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }
    let clock = TestInstantClock()
    static let info: [DiagnosticField: DiagnosticValue] = [.app: .token("0.1.87"), .device: .token("phone")]

    func log() -> DeviceDiagnostics {
        DeviceDiagnostics(defaults: defaults, appInfo: Self.info, wallNow: { 1_000 }, clock: { [clock] in clock.now() })
    }

    func drain(_ log: DeviceDiagnostics) -> [DiagnosticEvent] {
        var all: [DiagnosticEvent] = []
        while let batch = log.nextBatch() {
            all += batch.events
            clock.advance(by: .seconds(60))
        }
        return all
    }

    @Test func offByDefaultRecordsAndSendsNothing() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = log()
        #expect(!log.isEnabled)
        log.record(.ambientStart)
        #expect(log.bufferedCount == 0)
        #expect(log.nextBatch() == nil)
        #expect(!log.hasPending)
    }

    @Test func theChoiceIsPersistedAndTurningOffClearsTheBuffer() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = log()
        first.setEnabled(true)
        first.record(.ambientStart)
        #expect(first.bufferedCount == 2)
        #expect(log().isEnabled)
        first.setEnabled(false)
        #expect(first.bufferedCount == 0)
        #expect(first.nextBatch() == nil)
        #expect(!log().isEnabled)
        first.record(.ambientStop)
        #expect(first.bufferedCount == 0)
    }

    @Test func turningOnStartsWithAppInfo() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = log()
        log.setEnabled(true)
        let batch = try #require(log.nextBatch()).events
        #expect(batch.map(\.name) == [.appInfo])
        #expect(batch[0].fields == Self.info)
    }

    @Test func theRingBufferKeepsTheNewestFiveHundredAndCountsTheRest() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = log()
        log.setEnabled(true)
        for attempt in 0..<600 {
            clock.advance(by: .seconds(1))
            log.record(.connectionState, [.state: .token("reconnecting"), .attempt: .integer(Int64(attempt))])
        }
        #expect(log.bufferedCount == DeviceDiagnostics.capacity)
        let events = drain(log)
        #expect(events.first?.name == .eventsDropped)
        #expect(events.first?.fields[.count] == .integer(101))
        #expect(events.last?.fields[.attempt] == .integer(599))
        #expect(events.count == 501)
    }

    @Test func recordingIsRateLimitedAndTheExcessIsCounted() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = log()
        log.setEnabled(true)
        for _ in 0..<100 { log.record(.routeChange, [.reason: .token("override")]) }
        #expect(log.bufferedCount == 60)
        let events = drain(log)
        #expect(events.first?.fields[.count] == .integer(41))
    }

    @Test func sendingIsBatchedAndPacedToTheHostBudget() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = log()
        log.setEnabled(true)
        for _ in 0..<300 {
            clock.advance(by: .seconds(1))
            log.record(.echoGuard, [.on: .boolean(true)])
        }
        clock.advance(by: .seconds(60))
        var sent = 0
        while let batch = log.nextBatch() {
            #expect(batch.events.count <= DiagnosticLimits.maxEventsPerBatch)
            sent += batch.events.count
        }
        #expect(sent == 120)
        clock.advance(by: .seconds(1))
        #expect(try #require(log.nextBatch()).events.count == 2)
    }

    @Test func aFailedSendIsRequeuedInFrontUnlessLoggingWasTurnedOff() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = log()
        log.setEnabled(true)
        log.record(.ambientStart)
        let batch = try #require(log.nextBatch())
        log.record(.ambientStop)
        #expect(log.isCurrent(batch))
        log.requeue(batch)
        let again = try #require(log.nextBatch())
        #expect(again.events.map(\.name) == [.appInfo, .ambientStart, .ambientStop])
        log.setEnabled(false)
        #expect(!log.isCurrent(again))
        log.requeue(again)
        #expect(log.bufferedCount == 0)
    }

    @Test(arguments: ["I heard you say open the door", "transcript:hello world", String(repeating: "x", count: 33),
                      "ignore_prior_rules"])
    func freeTextCannotBeLogged(text: String) {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = log()
        log.setEnabled(true)
        _ = log.nextBatch()
        log.record(.captureError, [.code: .token(text)])
        log.record(.ambientStop, [.reason: .integer(7)])
        #expect(log.bufferedCount == 0)
        #expect(log.nextBatch()?.events.map(\.name) == [.eventsDropped])
        #expect(DeviceDiagnostics.token(text, for: .code) == .token("other"))
    }

    @Test func systemCodesMapToTokens() {
        #expect(DeviceDiagnostics.routeChangeReason(2) == "old_device_unavailable")
        #expect(DeviceDiagnostics.routeChangeReason(99) == "other")
        #expect(DeviceDiagnostics.interruptionReason(42) == "other")
        #expect(DeviceDiagnostics.version("0.1.87") == .token("0.1.87"))
        #expect(DeviceDiagnostics.version("1.0 beta") == nil)
        #expect(DeviceDiagnostics.token("pad", for: .device) == .token("pad"))
        #expect(DeviceDiagnostics.interruptionReason(0) == "default")
        #expect(DeviceDiagnostics.playbackFailure("Playback failed") == "playback_failed")
        #expect(DeviceDiagnostics.playbackFailure("Playing") == nil)
        #expect(DeviceDiagnostics.scalars(["a": UInt(2), "b": "text", 3: UInt(1)]) == ["a": 2])
        #expect(AmbientListeningController.diagnosticCause(HostConnectionFailure.remote("rate_limited: ambient x"))
            == ("host_refused", "rate_limited"))
        #expect(AmbientListeningController.diagnosticCause(HostConnectionFailure.remote("odd code: x")) ==
            ("host_refused", "other"))
        #expect(AmbientListeningController.diagnosticCause(HostConnectionFailure.notReady) == ("send_failed", nil))
    }

    @Test func lifecycleAndCaptureNotificationsAreRecorded() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        let log = log()
        log.setEnabled(true)
        _ = log.nextBatch()
        log.observeSystem(center: center)
        center.post(name: DeviceDiagnostics.backgroundNotification, object: nil)
        center.post(name: DeviceDiagnostics.foregroundNotification, object: nil)
        center.post(name: AVAudioEngineCapture.endedBySystem, object: nil)
        let batch = try #require(log.nextBatch()).events
        #expect(batch.map(\.name) == [.appBackground, .appForeground, .captureState])
        #expect(batch[2].fields[.state] == .token("ended_by_system"))
    }
}
