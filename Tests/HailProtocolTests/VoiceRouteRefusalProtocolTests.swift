import Foundation
import HailProtocol
import Testing

/// A voice route refusal (#636) has its own request-refusal code, so a device that advertised `request_refusals`
/// keeps its connection without reading the message.
@Suite struct VoiceRouteRefusalProtocolTests {
    @Test func aVoiceRouteRefusalHasItsOwnRequestRefusalCode() throws {
        let frame = Frame(timestamp: 1, source: "haild", payload: .control(.error(
            code: .voiceRouteRefused, message: "voice route: Deck is offline; nothing was sent"
        )))
        let data = try FrameCoding.encode(frame)
        #expect(try #require(String(bytes: data, encoding: .utf8)).contains(#""code":"voice_route_refused""#))
        #expect(try FrameCoding.decode(data) == frame)
        #expect(ErrorCode.voiceRouteRefused.rawValue == "voice_route_refused")
        #expect(ErrorCode.voiceRouteRefused.isRequestRefusal && ErrorCode.pasteRefused.isRequestRefusal)
        #expect(!ErrorCode.unknownTarget.isRequestRefusal && !ErrorCode.notAllowed.isRequestRefusal)
    }
}
