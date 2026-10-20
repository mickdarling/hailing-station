#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// The allow-list file (#636, slice 1): off when absent, strict when present, trusted only when private.
@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceRoutesFileTests {
    static let valid = #"""
        {"version": 1, "default": "tmux:hailing-test", "routes": [
          {"target": "tmux:hailing-test", "name": "Hailing Scratch", "aliases": ["Scratch"]},
          {"target": "tmux:deck", "name": "Deck"}]}
        """#

    func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("routes.json"))
    }

    @Test func theFileIsOffWhenAbsentAndLoadsWhenValid() throws {
        try withFile { file in
            #expect(try VoiceRoutes.load(file) == nil)
            try Data(Self.valid.utf8).write(to: file)
            let routes = try #require(try VoiceRoutes.load(file))
            #expect(routes.defaultTarget == "tmux:hailing-test")
            #expect(routes.routes.map(\.name) == ["Hailing Scratch", "Deck"])
            #expect(routes.routes.first?.aliases == ["Scratch"] && routes.routes.last?.aliases == [])
        }
    }

    @Test(arguments: [
        ("not json", VoiceRoutes.LoadError.malformed),
        (#"{"version": 2, "default": "tmux:deck", "routes": [{"target": "tmux:deck", "name": "Deck"}]}"#, .malformed),
        (#"{"version": 1, "default": "tmux:deck", "routes": [{"target": "tmux:deck", "name": "Deck"}], "x": 1}"#,
         .malformed),
        (#"{"version": 1, "default": "tmux:deck", "routes": [{"target": "tmux:deck", "name": "Deck", "voice": "x"}]}"#,
         .malformed),
        (#"{"version": 1, "default": "tmux:deck", "routes": [{"target": "tmux:deck"}]}"#, .malformed),
        (#"{"version": 1, "default": "tmux:deck", "routes": [{"target": "tmux:deck", "name": "D", "aliases": [1]}]}"#,
         .malformed),
        (#"{"version": 1, "default": "tmux:deck", "routes": [{"target": "tmux:deck", "name": "D", "aliases": "D"}]}"#,
         .malformed),
        (#"{"version": 1, "default": "tmux:other", "routes": [{"target": "tmux:deck", "name": "Deck"}]}"#,
         .unknownDefault),
        (#"{"version": 1, "default": "tmux:deck", "routes": [{"target": "tmux:deck;rm", "name": "Deck"}]}"#,
         .invalidTarget)
    ])
    func aMalformedFileIsRefused(_ body: String, _ error: VoiceRoutes.LoadError) throws {
        try withFile { file in
            try Data(body.utf8).write(to: file)
            #expect(throws: error) { try VoiceRoutes.load(file) }
        }
    }

    /// Anyone else able to write the file could send the owner's spoken requests to a session of their choosing.
    @Test func aFileOthersCouldWriteOrThatIsNotARegularFileIsUnsafe() throws {
        try withFile { file in
            try Data(Self.valid.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
            #expect(throws: VoiceRoutes.LoadError.unsafe) { try VoiceRoutes.load(file) }
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: VoiceRoutes.LoadError.unsafe) { try VoiceRoutes.load(file) }
            let remote = try #require(URL(string: "https://example.com/routes.json"))
            #expect(throws: VoiceRoutes.LoadError.unsafe) { try VoiceRoutes.load(remote) }
        }
    }
}
#endif
