import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #608: an `error` whose code is a request refusal ends that request, never the connection. The device says it
/// takes them in its `hello`; every other code still ends the connection.
@Suite struct RequestRefusalTests {
    private actor Events {
        private(set) var values: [HostReplyEvent] = []
        func append(_ event: HostReplyEvent) { values.append(event) }
    }

    @Test func theSharedSetIsTheOnlyNonFatalCodes() {
        #expect(RequestRefusals.capability == "request_refusals")
        #expect(RequestRefusals.codes == [.pasteRefused])
        #expect(ErrorCode.pasteRefused.isRequestRefusal)
        for code in [ErrorCode.unauthorized, .unknownTarget, .notAllowed, .lockdown, .rateLimited, .protocolVersion,
                     .malformed, .unknown("paste_refused_later")] {
            #expect(!code.isRequestRefusal)
        }
    }

    @Test func aRequestRefusalKeepsTheConnectionAndOtherErrorsDoNot() async throws {
        let mac = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        let events = Events()
        await connector.enqueue(.socket(socket), for: mac.url)
        let connection = HostConnection(endpoint: mac, connector: connector, replyObserver: { await events.append($0) })
        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        guard case .control(.hello(let hello)) = try await socket.sentFrames().first?.payload else {
            Issue.record("expected the device's hello")
            return
        }
        #expect(hello.capabilities.contains(RequestRefusals.capability))
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["send_text"], deviceName: "Mac"
        )))
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        // Wording is irrelevant: the code decides.
        try await socket.push(.error(code: .pasteRefused, message: "target requires confirmation at the Mac"))
        try await waitUntil { await events.values.count == 1 }
        #expect(await connection.currentSnapshot().state == .ready)
        try await socket.push(.error(code: .notAllowed, message: "pastes go only to agent sessions"))
        try await waitUntil { await connection.currentSnapshot().state != .ready }
        await connection.disconnect()
    }
}
