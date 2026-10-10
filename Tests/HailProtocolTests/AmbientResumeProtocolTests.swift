import Foundation
import Testing
@testable import HailProtocol

/// #373: `resume` marks a device's own automatic restart of ambient listening. It is `true` or absent, and only on a
/// stream's first segment. The rejections live in fixtures/invalid (audio-resume-*).
@Suite struct AmbientResumeProtocolTests {
    private let stream = UUID(uuid: (0x0B, 0x0B, 0x0B, 0x0B, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0xAA))

    private func segment(sequence: Int = 0, isResume: Bool) -> AudioPayload {
        AudioPayload(
            codec: .pcm16, sampleRate: 16_000, channels: 1, sequence: sequence, streamID: stream, isFinal: false,
            bytes: Data([0, 0]), isResume: isResume
        )
    }

    private func encoded(_ audio: AudioPayload) throws -> String {
        let frame = Frame(timestamp: 1, source: "terminal", payload: .audio(audio))
        let data = try FrameCoding.encode(frame)
        #expect(try FrameCoding.decode(data) == frame)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test func resumeIsSentOnlyWhenTrue() throws {
        #expect(try encoded(segment(isResume: true)).contains(#""resume":true"#))
        #expect(try !encoded(segment(isResume: false)).contains("resume"))
    }

    @Test func aSegmentWithoutResumeDecodesAsNotResuming() throws {
        let json = #"{"codec":"pcm16","sampleRate":16000,"channels":1,"sequence":0,"#
            + #""streamId":"0B0B0B0B-0000-4000-8000-0000000000AA","final":false,"bytes":"AAA="}"#
        let audio = try JSONDecoder().decode(AudioPayload.self, from: Data(json.utf8))
        #expect(!audio.isResume)
    }

    @Test func everyInvalidResumeFixtureIsRefusedByTheDecoder() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../fixtures/invalid").standardized
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("audio-resume-") }
        #expect(names.count == 4)
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            #expect(throws: (any Error).self, "\(name)") { try FrameCoding.decode(data) }
        }
    }
}
