import Foundation
import Testing
@testable import HailProtocol

@Suite struct FrameRoundTripTests {
    private static let id = UUID(uuidString: "0B0B0B0B-0000-4000-8000-000000000001") ?? UUID()

    private func roundTrip(_ payload: FramePayload, target: String? = "tmux:demo") throws -> Frame {
        let frame = Frame(
            id: Self.id, timestamp: 1_700_000_000_000, target: target, source: "terminal", payload: payload
        )
        let data = try FrameCoding.encode(frame)
        let decoded = try FrameCoding.decode(data)
        #expect(decoded == frame)
        return decoded
    }

    @Test func textRoundTrips() throws {
        let frame = try roundTrip(.text(TextPayload(text: "hello, host", isFinal: true)))
        #expect(frame.payload.type == .text)
    }

    @Test func audioRoundTripsWithBytes() throws {
        let bytes = Data([0, 1, 2, 250, 255])
        let payload = AudioPayload(codec: .opus, sampleRate: 48_000, channels: 1, sequence: 3, bytes: bytes)
        let frame = try roundTrip(.audio(payload), target: nil)
        guard case .audio(let decoded) = frame.payload else { Issue.record("expected audio"); return }
        #expect(decoded.bytes == bytes)
        #expect(frame.target == nil)
    }

    @Test func imageAndScreenFrameRoundTrip() throws {
        _ = try roundTrip(.image(ImagePayload(mimeType: "image/png", width: 2, height: 2, bytes: Data([9]))))
        _ = try roundTrip(.frame(ScreenFramePayload(
            mimeType: "image/jpeg", width: 1, height: 1, streamID: "win-1", index: 7, bytes: Data([8])
        )))
    }

    @Test func wireKeysAreShortAndStable() throws {
        let frame = Frame(id: Self.id, timestamp: 42, source: "terminal", payload: .text(TextPayload(text: "x")))
        let json = try #require(String(bytes: FrameCoding.encode(frame), encoding: .utf8))
        let expectedPrefix = "{\"id\":\"0B0B0B0B-0000-4000-8000-000000000001\","
            + "\"payload\":{\"final\":true,\"text\":\"x\"}"
        #expect(json.hasPrefix(expectedPrefix))
        #expect(json.contains("\"ts\":42"))
        #expect(json.contains("\"type\":\"text\""))
        #expect(json.contains("\"v\":\(ProtocolVersion.current)"))
        #expect(!json.contains("target"))
    }
}
