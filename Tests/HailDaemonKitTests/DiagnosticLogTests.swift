import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// A manual monotonic clock for rate-limit tests.
final class DiagnosticTestClock: Sendable {
    private let base = ContinuousClock.now
    private let offset = Mutex(Duration.zero)

    func advance(_ by: Duration) { offset.withLock { $0 += by } }
    var now: ContinuousClock.Instant { base + offset.withLock { $0 } }
}

func diagnosticEvents(_ count: Int, name: DiagnosticEventName = .routeChange) throws -> [DiagnosticEvent] {
    try (0..<count).map { index in
        try DiagnosticEvent(name, timestamp: Int64(1_000 + index), fields: [.reason: .token("new_device_available")])
    }
}

/// The opt-in host sink (#234): owner-only storage, bounded size with one rotation, rate limits that drop
/// silently, and no writes through links or into unsafe directories.
@Suite struct DiagnosticLogTests {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hail-diagnostics-\(UUID().uuidString)", isDirectory: true)
    var dir: URL { scratch.appendingPathComponent("diagnostics", isDirectory: true) }
    var file: URL { dir.appendingPathComponent(DiagnosticLog.fileName) }
    var rotated: URL { dir.appendingPathComponent(DiagnosticLog.rotatedName) }
    let session = UUID()

    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }

    func lines(_ url: URL) throws -> [DiagnosticRecord] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(DiagnosticRecord.self, from: Data($0.utf8))
        }
    }

    func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func storesTaggedRecordsOwnerOnly() async throws {
        defer { cleanUp() }
        let log = DiagnosticLog(directory: dir, now: { 42 })
        let events = try diagnosticEvents(2)
        #expect(await log.record(events, session: session, device: "Mick's\u{0007} iPhone") == 2)
        let stored = try lines(file)
        #expect(stored == events.map {
            DiagnosticRecord(received: 42, session: session, device: "Mick's iPhone", event: $0)
        })
        #expect(try mode(file) == 0o600)
        #expect(try mode(dir) == 0o700)
    }

    @Test func anExistingLooseFileIsTightenedTo0600() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try #require(FileManager.default.createFile(atPath: file.path, contents: Data()))
        try #require(chmod(file.path, 0o644) == 0)
        #expect(await DiagnosticLog(directory: dir).record(try diagnosticEvents(1), session: session, device: "d") == 1)
        #expect(try mode(file) == 0o600)
    }

    @Test func rotatesOnceAndStaysWithinTwoFiles() async throws {
        defer { cleanUp() }
        let log = DiagnosticLog(directory: dir, maxFileBytes: 2_048,
                                sessionRate: .init(capacity: 10_000, perSecond: 0),
                                hostRate: .init(capacity: 10_000, perSecond: 0))
        for _ in 0..<40 { await log.record(try diagnosticEvents(4), session: session, device: "d") }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == [DiagnosticLog.rotatedName, DiagnosticLog.fileName].sorted())
        for url in [file, rotated] {
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? .max <= 2_048)
            #expect(try mode(url) == 0o600)
        }
        #expect(DiagnosticLog.defaultMaxFileBytes * 2 == 5 * 1_024 * 1_024)
    }

    @Test func excessEventsAreDroppedAndCountedNotRefused() async throws {
        defer { cleanUp() }
        let clock = DiagnosticTestClock()
        let log = DiagnosticLog(directory: dir, sessionRate: .init(capacity: 3, perSecond: 1),
                                clock: { clock.now })
        #expect(await log.record(try diagnosticEvents(5), session: session, device: "d") == 3)
        #expect(await log.record(try diagnosticEvents(1), session: session, device: "d") == 0)
        clock.advance(.seconds(2))
        #expect(await log.record(try diagnosticEvents(1), session: session, device: "d") == 1)
        let stored = try lines(file).map(\.event)
        // Each stored batch is led by a count of what this session lost since the last stored batch.
        #expect(stored.map(\.name) == [.eventsDropped, .routeChange, .routeChange, .routeChange,
                                       .eventsDropped, .routeChange])
        #expect(stored[0].fields == [.count: .integer(2), .code: .token("host_rate_limit")])
        #expect(stored[4].fields == [.count: .integer(1), .code: .token("host_rate_limit")])
    }

    @Test func theHostBudgetIsSharedAcrossSessions() async throws {
        defer { cleanUp() }
        let log = DiagnosticLog(directory: dir, hostRate: .init(capacity: 4, perSecond: 0), clock: { .now })
        #expect(await log.record(try diagnosticEvents(3), session: UUID(), device: "a") == 3)
        #expect(await log.record(try diagnosticEvents(3), session: UUID(), device: "b") == 1)
    }

    @Test func refusesToWriteThroughALinkOrIntoAnOpenDirectory() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let elsewhere = scratch.appendingPathComponent("elsewhere")
        try #require(FileManager.default.createFile(atPath: elsewhere.path, contents: Data()))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        let log = DiagnosticLog(directory: dir)
        #expect(await log.record(try diagnosticEvents(1), session: session, device: "d") == 0)
        #expect(try Data(contentsOf: elsewhere).isEmpty)
        try FileManager.default.removeItem(at: file)
        try #require(chmod(dir.path, 0o755) == 0)
        #expect(await log.record(try diagnosticEvents(1), session: session, device: "d") == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await log.writeFailures == 2)
    }

    @Test func clearRemovesBothFilesAndWritingResumes() async throws {
        defer { cleanUp() }
        let log = DiagnosticLog(directory: dir, maxFileBytes: 1_024,
                                sessionRate: .init(capacity: 1_000, perSecond: 0))
        for _ in 0..<10 { await log.record(try diagnosticEvents(4), session: session, device: "d") }
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        try DiagnosticLog.clear(directory: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        try DiagnosticLog.clear(directory: dir)
        #expect(await log.record(try diagnosticEvents(1), session: session, device: "d") == 1)
        #expect(try lines(file).count == 1)
    }

    @Test func deviceNamesAreBounded() {
        #expect(DiagnosticLog.deviceName(String(repeating: "x", count: 100)).count == 64)
        #expect(DiagnosticLog.deviceName("\n\t") == "unnamed")
    }
}
