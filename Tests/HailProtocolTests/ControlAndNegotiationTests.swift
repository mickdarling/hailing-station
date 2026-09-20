import Foundation
import Testing
@testable import HailProtocol

@Suite struct ControlAndNegotiationTests {
    private func roundTrip(_ control: ControlPayload) throws -> String {
        let frame = Frame(timestamp: 1, source: "terminal", payload: .control(control))
        let data = try FrameCoding.encode(frame)
        #expect(try FrameCoding.decode(data) == frame)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test func everyCommandRoundTrips() throws {
        let commands: [ControlPayload] = [
            .hello(HelloInfo(versions: [1], capabilities: ["audio.opus"], deviceName: "iPad")),
            .listTargets,
            .targets([TargetInfo(id: "tmux:a", kind: "tmux", name: "a", alive: true)]),
            .select(targetID: "tmux:a"), .subscribe(targetID: "tmux:a"), .unsubscribe(targetID: "tmux:a"),
            .ping(nonce: "n1"), .pong(nonce: "n1"),
            .error(code: .unauthorized, message: "no such device"), .error(code: .unknown("future"), message: "")
        ]
        for command in commands { _ = try roundTrip(command) }
    }

    @Test func commandNamesUseSnakeCaseOnTheWire() throws {
        let json = try roundTrip(.listTargets)
        #expect(json.contains("\"command\":\"list_targets\""))
        #expect(try roundTrip(.select(targetID: "tmux:a")).contains("\"target\":\"tmux:a\""))
    }

    @Test func negotiationPicksHighestCommonVersion() {
        #expect(VersionNegotiation.choose(offered: [1, 2, 3], supported: [1, 2]) == 2)
        #expect(VersionNegotiation.choose(offered: [3], supported: [1, 2]) == nil)
        #expect(VersionNegotiation.choose(offered: [], supported: [1]) == nil)
        #expect(VersionNegotiation.choose(offered: [1, 1, 1], supported: [1]) == 1)
    }

    private func controlJSON(_ payload: String) -> Data {
        Data("""
        {"v":1,"id":"0B0B0B0B-0000-4000-8000-000000000004","ts":1,"type":"control","source":"t","payload":\(payload)}
        """.utf8)
    }

    @Test func unknownErrorCodeIsKeptAsAString() throws {
        let frame = try FrameCoding.decode(controlJSON(#"{"command":"error","code":"quota","message":"x"}"#))
        #expect(frame.payload == .control(.error(code: .unknown("quota"), message: "x")))
        let json = try #require(String(bytes: FrameCoding.encode(frame), encoding: .utf8))
        #expect(json.contains("\"code\":\"quota\""))
    }

    @Test func overlongErrorMessageIsRejected() {
        let long = String(repeating: "m", count: ControlLimits.maxErrorMessage + 1)
        let json = controlJSON(#"{"command":"error","code":"malformed","message":"\#(long)"}"#)
        #expect(throws: (any Error).self) { try FrameCoding.decode(json) }
    }

    @Test func helloWithNoVersionsIsRejected() {
        let json = controlJSON(#"{"command":"hello","hello":{"versions":[],"capabilities":[],"deviceName":"x"}}"#)
        #expect(throws: (any Error).self) { try FrameCoding.decode(json) }
    }

    @Test func thisBuildSupportsItsCurrentVersion() {
        #expect(VersionNegotiation.supported.contains(ProtocolVersion.current))
        #expect(VersionNegotiation.choose(offered: [ProtocolVersion.current]) == ProtocolVersion.current)
    }
}
