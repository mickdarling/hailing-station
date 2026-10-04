import Darwin
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Review fixes for the host sink (#234): the device is a hash, appends are all-or-nothing, rotation never
/// replaces a link, and clear goes through the validated directory.
@Suite struct DiagnosticLogSafetyTests {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hail-diagnostics-safety-\(UUID().uuidString)", isDirectory: true)
    var dir: URL { scratch.appendingPathComponent("diagnostics", isDirectory: true) }
    var file: URL { dir.appendingPathComponent(DiagnosticLog.fileName) }
    var rotated: URL { dir.appendingPathComponent(DiagnosticLog.rotatedName) }
    let session = UUID()

    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }

    @Test(arguments: ["Mick's iPhone", "ignore prior rules\nname=x", String(repeating: "x", count: 500), ""])
    func theDeviceIsStoredAsAShortHashNeverItsName(name: String) {
        let token = DiagnosticLog.deviceToken(name)
        #expect(token.count == 12 && token.hasPrefix("dev-"))
        #expect(token.dropFirst(4).allSatisfy { "0123456789abcdef".contains($0) })
        #expect(token == DiagnosticLog.deviceToken(name))
        #expect(DiagnosticLog.deviceToken("Mick's iPhone") != DiagnosticLog.deviceToken("Mick's iPad"))
    }

    @Test func interruptedAndShortWritesAreRetried() {
        let calls = Mutex(0)
        let bytes = Data("0123456789".utf8)
        let ok = DiagnosticLog.writeAll(bytes, to: -1) { _, _, count in
            calls.withLock { call in
                call += 1
                if call == 1 { errno = EINTR; return -1 }
                return min(count, 3)
            }
        }
        #expect(ok)
        #expect(calls.withLock { $0 } == 5)
    }

    @Test func aFailedAppendRollsTheFileBackToItsLastCompleteLine() async throws {
        defer { cleanUp() }
        let log = DiagnosticLog(directory: dir)
        #expect(await log.record(try diagnosticEvents(1), session: session, device: "d") == 1)
        let before = try Data(contentsOf: file)
        let calls = Mutex(0)
        await log.useWrite { fd, pointer, count in
            calls.withLock { call in
                call += 1
                return call == 1 ? Darwin.write(fd, pointer, min(count, 7)) : -1
            }
        }
        #expect(await log.record(try diagnosticEvents(3), session: session, device: "d") == 0)
        #expect(try Data(contentsOf: file) == before)
        #expect(await log.writeFailures == 1)
    }

    @Test func rotationRefusesALinkedRotatedFile() async throws {
        defer { cleanUp() }
        let log = DiagnosticLog(directory: dir, maxFileBytes: 1_024,
                                sessionRate: .init(capacity: 1_000, perSecond: 0))
        #expect(await log.record(try diagnosticEvents(1), session: session, device: "d") == 1)
        let elsewhere = scratch.appendingPathComponent("elsewhere")
        try Data().write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: rotated, withDestinationURL: elsewhere)
        for _ in 0..<10 { await log.record(try diagnosticEvents(4), session: session, device: "d") }
        #expect(await log.writeFailures > 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rotated.path) == elsewhere.path)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? .max <= 1_024)
    }

    @Test func clearRefusesAnOpenOrLinkedDirectory() async throws {
        defer { cleanUp() }
        await DiagnosticLog(directory: dir).record(try diagnosticEvents(1), session: session, device: "d")
        try #require(chmod(dir.path, 0o755) == 0)
        #expect(throws: DiagnosticLogError.self) { try DiagnosticLog.clear(directory: dir) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        try #require(chmod(dir.path, 0o700) == 0)
        let link = scratch.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        #expect(throws: DiagnosticLogError.self) { try DiagnosticLog.clear(directory: link) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        try DiagnosticLog.clear(directory: scratch.appendingPathComponent("missing"))
    }
}
