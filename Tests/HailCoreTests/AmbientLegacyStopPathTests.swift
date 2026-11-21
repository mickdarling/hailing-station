// This tripwire flags added .legacy, unqualified legacy( and LegacyStopPath tokens throughout Sources and Apps.
// It also flags added stop entry-point calls or unapplied references in pinned controller files and changes to that set.
// Code review must trace indirection through renamed receivers, new closure chains and callbacks such as
// StationMenuStatus.setListening. The lexer skips extended regex literals but does not recognize bare /.../ literals.
import Foundation
import Testing
@testable import HailCore

@Suite struct AmbientLegacyStopPathTests {
    typealias Path = AmbientListeningState.LegacyStopPath
    static let paths: [Path] = [
        .systemCaptureEnded, .socketBindingLost, .privacySendFailed, .privacyUnconfirmed,
        .leftForeground, .captureStartFailed, .sendCancelled, .encodingFailed, .sendFailed,
        .hostRefused, .retriesExhausted, .replacementFailed, .diagnosticsDismissed
    ]

    @Test func onlyRecordedSitesCanRequestALegacyStop() throws {
        #expect(Path.allCases == Self.paths)
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = tests.appendingPathComponent("Fixtures/ambient-stop-unapplied-lines.json")
        let exceptions = try Self.unappliedExceptions(in: fixture)
        let root = tests.deletingLastPathComponent()
        var legacyCounts: [String: [String: Int]] = [:]
        var controllerCounts: [String: [String: Int]] = [:]
        var unappliedLines: [String: [String: Int]] = [:]
        for tree in ["Sources", "Apps"] {
            for file in try Self.swiftFiles(in: root.appendingPathComponent(tree)) {
                let path = String(file.path.dropFirst(root.path.count + 1))
                let source = try String(contentsOf: file, encoding: .utf8)
                let inventory = try StopReferenceSource(source, definesStopPaths: Self.stopDefinitions.contains(path))
                if !inventory.legacyCounts.isEmpty { legacyCounts[path] = inventory.legacyCounts }
                if inventory.includesEntryPoints { controllerCounts[path] = inventory.controllerCounts }
                if !inventory.unappliedLines.isEmpty { unappliedLines[path] = inventory.unappliedLines }
            }
        }
        #expect(legacyCounts == Self.legacyCounts)
        #expect(controllerCounts == Self.controllerCounts)
        #expect(unappliedLines == exceptions)
    }

    private static func unappliedExceptions(in fixture: URL) throws -> [String: [String: Int]] {
        let lines = try JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: fixture))
        return try lines.mapValues { sites in
            try sites.reduce(into: [String: Int]()) { counts, site in
                var lexer = StopReferenceLexer(site.key)
                let spelling = try lexer.tokens().joined(separator: " ")
                counts[spelling, default: 0] += site.value
            }
        }
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.isDirectoryKey])
        return try entries.sorted { $0.path < $1.path }.flatMap { file -> [URL] in
            if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                return try swiftFiles(in: file)
            }
            return file.pathExtension == "swift" ? [file] : []
        }
    }
}
