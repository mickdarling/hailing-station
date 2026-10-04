import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Review fixes for the phone's log (#234): the enable generation keeps the toggle's promise, every drop is
/// counted, and a drop alone wakes the sender.
@MainActor
@Suite struct DeviceDiagnosticsGenerationTests {
    let suite = "hail-device-diagnostics-generation-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }
    let clock = TestInstantClock()

    func log() -> DeviceDiagnostics {
        DeviceDiagnostics(defaults: defaults, appInfo: [.app: .token("0.1.87")], wallNow: { 1_000 },
                          clock: { [clock] in clock.now() })
    }

    func drain(_ log: DeviceDiagnostics) -> [DiagnosticEvent] {
        var all: [DiagnosticEvent] = []
        while let batch = log.nextBatch() {
            all += batch.events
            clock.advance(by: .seconds(60))
        }
        return all
    }

    @Test func aBatchFromBeforeAnOffAndOnIsNeitherCurrentNorRequeued() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = log()
        log.setEnabled(true)
        log.record(.ambientStart)
        let stale = try #require(log.nextBatch())
        log.setEnabled(false)
        log.setEnabled(true)
        #expect(!log.isCurrent(stale))
        log.requeue(stale)
        #expect(try #require(log.nextBatch()).events.map(\.name) == [.appInfo])
    }

    @Test func requeueOverflowIsCountedAsDropped() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = log()
        log.setEnabled(true)
        let batch = try #require(log.nextBatch())
        for attempt in 0..<DeviceDiagnostics.capacity {
            clock.advance(by: .seconds(1))
            log.record(.connectionState, [.state: .token("reconnecting"), .attempt: .integer(Int64(attempt))])
        }
        log.requeue(batch)
        #expect(log.bufferedCount == DeviceDiagnostics.capacity)
        let events = drain(log)
        #expect(events.first?.name == .eventsDropped)
        #expect(events.first?.fields[.count] == .integer(1))
    }

    @Test func aDropAloneWakesTheSender() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = log()
        log.setEnabled(true)
        _ = log.nextBatch()
        var wakes = 0
        log.onPending = { wakes += 1 }
        log.record(.captureError, [.code: .token("not a code")])
        #expect(wakes == 1)
        #expect(log.hasPending && log.bufferedCount == 0)
    }
}
