import Foundation
import Testing
@testable import HailProtocol

/// #735 S-7a0: the host's launch id in its hello, so a device can tell a host that restarted (privacy ended, #809)
/// from a connection that only dropped. Optional, a UUID or nothing.
@Suite struct HelloHostInstanceTests {
    private func decodeControl(_ payload: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(payload.utf8))
    }

    @Test func theHostInstanceIsOptionalAndAUUID() throws {
        let launch = try #require(UUID(uuidString: "5E5E5E5E-0000-4000-8000-000000000001"))
        let host = try decodeControl(
            #"{"command":"hello","hello":{"versions":[1],"capabilities":[],"deviceName":"Mac","#
                + #""hostInstance":"5E5E5E5E-0000-4000-8000-000000000001"}}"#
        )
        #expect(host == .hello(HelloInfo(versions: [1], capabilities: [], deviceName: "Mac", hostInstance: launch)))
        // A device's hello carries none, as before.
        let device = try decodeControl(
            #"{"command":"hello","hello":{"versions":[1],"capabilities":[],"deviceName":"x"}}"#
        )
        #expect(device == .hello(HelloInfo(versions: [1], capabilities: [], deviceName: "x")))
        // Anything that is not a UUID fails the hello.
        for bad in [#""restarted-at-noon""#, "42", "true", #""""#] {
            #expect(throws: DecodingError.self) {
                try decodeControl(#"{"command":"hello","hello":{"versions":[1],"capabilities":[],"deviceName":"x","#
                    + #""hostInstance":\#(bad)}}"#)
            }
        }
    }

    /// An explicit null is the same as no key: no instance, which proves nothing (the schema refuses it as a type).
    @Test func anExplicitNullIsNoInstance() throws {
        let hello = try decodeControl(
            #"{"command":"hello","hello":{"versions":[1],"capabilities":[],"deviceName":"x","hostInstance":null}}"#
        )
        #expect(hello == .hello(HelloInfo(versions: [1], capabilities: [], deviceName: "x")))
    }

    @Test func withoutAnInstanceTheHelloIsByteIdenticalToAnOlderBuilds() throws {
        let frame = Frame(timestamp: 1, source: "host",
                          payload: .control(.hello(HelloInfo(versions: [1], capabilities: [], deviceName: "x"))))
        let data = try FrameCoding.encode(frame)
        #expect(!(try #require(String(bytes: data, encoding: .utf8))).contains("hostInstance"))
        #expect(try FrameCoding.decode(data) == frame)
    }
}
