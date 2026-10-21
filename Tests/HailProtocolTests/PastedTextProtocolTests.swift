import Foundation
import Testing
@testable import HailProtocol

/// #608: a final text frame may carry text the user pasted. It is optional, absent on the wire when nil, non-empty,
/// at most `maxPastedTextBytes` of UTF-8, and only on a final frame. The rejections live in fixtures/invalid
/// (text-pasted-*).
@Suite struct PastedTextProtocolTests {
    private func roundTrip(_ text: TextPayload) throws -> String {
        let frame = Frame(timestamp: 1, target: "tmux:a", source: "terminal", payload: .text(text))
        let data = try FrameCoding.encode(frame)
        #expect(try FrameCoding.decode(data) == frame)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test func aPasteRoundTripsBesideTheSpokenText() throws {
        let json = try roundTrip(TextPayload(text: "compare this", pasted: PastedText(text: "line one\nline two")))
        #expect(json.contains(#""pasted":{"text":"line one\nline two"}"#))
    }

    @Test func aPasteMaySendOnItsOwn() throws {
        _ = try roundTrip(TextPayload(text: "", pasted: PastedText(text: "only the paste")))
    }

    @Test func aFrameWithoutAPasteEncodesAsBefore() throws {
        #expect(try !roundTrip(TextPayload(text: "run the tests")).contains("pasted"))
    }

    @Test func anOlderFrameWithoutPastedDecodesAsNoPaste() throws {
        let text = try JSONDecoder().decode(TextPayload.self, from: Data(#"{"text":"hi","final":true}"#.utf8))
        #expect(text.pasted == nil)
    }

    @Test func thePasteCapIsExactlyThirtyTwoKilobytesOfUTF8() throws {
        #expect(PayloadLimits.maxPastedTextBytes == 32_768)
        // Three-byte scalars: at the cap by bytes, far under it by characters, so bytes are what is counted.
        let atCap = String(repeating: "€", count: PayloadLimits.maxPastedTextBytes / 3)
        _ = try roundTrip(TextPayload(text: "", pasted: PastedText(text: atCap)))
        let over = String(repeating: "€", count: PayloadLimits.maxPastedTextBytes / 3 + 1)
        let json = #"{"text":"","final":true,"pasted":{"text":"\#(over)"}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TextPayload.self, from: Data(json.utf8)) }
    }

    @Test func aFullPasteStillFitsTheDefaultFrameCap() throws {
        let frame = Frame(timestamp: 1, target: "tmux:a", source: "terminal", payload: .text(TextPayload(
            text: String(repeating: "s", count: PayloadLimits.maxTextBytes),
            pasted: PastedText(text: String(repeating: "p", count: PayloadLimits.maxPastedTextBytes))
        )))
        #expect(try FrameCoding.encode(frame).count <= PayloadLimits.defaultMaxFrameBytes)
    }

    /// A paste request's refusal has its own code, so a device need not read the message to keep its connection.
    @Test func aPasteRefusalHasItsOwnErrorCode() throws {
        let frame = Frame(timestamp: 1, source: "haild", payload: .control(.error(
            code: .pasteRefused, message: "pastes go only to agent sessions"
        )))
        let data = try FrameCoding.encode(frame)
        #expect(try #require(String(bytes: data, encoding: .utf8)).contains(#""code":"paste_refused""#))
        #expect(try FrameCoding.decode(data) == frame)
        #expect(ErrorCode.pasteRefused.rawValue == "paste_refused")
    }

    @Test func everyInvalidPastedFixtureIsRefusedByTheDecoder() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../fixtures/invalid").standardized
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("text-pasted-") }
        #expect(names.count == 5)
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            #expect(throws: DecodingError.self, "\(name)") { try FrameCoding.decode(data) }
        }
    }
}
