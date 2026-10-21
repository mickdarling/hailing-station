import Foundation
import Testing
@testable import HailProtocol

/// #606: a reply's text frame carries the spoken words in `text` and optional unspoken Markdown in `metadata`. The
/// rejections live in fixtures/invalid (text-metadata-*).
@Suite struct ReplyMetadataProtocolTests {
    private let descriptor = ReplyDescriptor(
        id: UUID(uuid: (0x0B, 0x0B, 0x0B, 0x0B, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x01, 0x04)),
        hostID: "mac-test", targetID: "tmux:test"
    )

    private func encoded(_ text: TextPayload) throws -> String {
        let frame = Frame(timestamp: 1, target: "tmux:test", source: "mac-test", payload: .text(text))
        let data = try FrameCoding.encode(frame)
        #expect(try FrameCoding.decode(data) == frame)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test func metadataRoundTripsBesideTheSpokenText() throws {
        let markdown = "- [#1](https://example.invalid/pull/1)\n- `Sources/Example.swift`"
        let json = try encoded(TextPayload(text: "Done.", reply: descriptor, metadata: markdown))
        #expect(json.contains(#""metadata":"#))
        #expect(json.contains(#""text":"Done.""#))
    }

    @Test func aReplyWithoutMetadataHasNoMetadataKey() throws {
        #expect(try !encoded(TextPayload(text: "Done.", reply: descriptor)).contains("metadata"))
    }

    @Test func aPayloadThatPredatesMetadataDecodesWithoutIt() throws {
        let json = #"{"text":"Done.","final":true}"#
        let text = try JSONDecoder().decode(TextPayload.self, from: Data(json.utf8))
        #expect(text.metadata == nil)
    }

    /// The cap counts UTF-8 bytes, as `text` does: 16 KiB of four-byte characters is a quarter as many characters.
    @Test func theCapCountsUTF8Bytes() throws {
        let atCap = String(repeating: "m", count: PayloadLimits.maxMetadataBytes)
        _ = try encoded(TextPayload(text: "Done.", reply: descriptor, metadata: atCap))
        let wide = String(repeating: "🙂", count: PayloadLimits.maxMetadataBytes / 4 + 1)
        let frame = Frame(timestamp: 1, target: "tmux:test", source: "mac-test",
                          payload: .text(TextPayload(text: "Done.", reply: descriptor, metadata: wide)))
        let data = try FrameCoding.encode(frame)
        #expect(throws: (any Error).self) { try FrameCoding.decode(data) }
    }

    @Test func everyInvalidMetadataFixtureIsRefusedByTheDecoder() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../fixtures/invalid").standardized
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("text-metadata-") }
        #expect(names.count == 4)
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            #expect(throws: (any Error).self, "\(name)") { try FrameCoding.decode(data) }
        }
    }
}
