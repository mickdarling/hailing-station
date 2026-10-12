#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// rightyo#164 / rightyo#172: RightyO says when the owner's voice is not recognised on this input; haild opts the child
/// in, passes the device's route kind, and shows the status only on the device whose stream it is. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientOwnerVoiceTests {
    private static func line(_ fields: String, sequence: Int = 2) throws -> RightyoInputEvent {
        let prefix = #"{"schema_version": 1, "session_id": "s", "sequence": \#(sequence), "emitted_at_ms": 0, "#
        return try RightyoInputEvent.decode(Data((prefix + fields + "}").utf8))
    }

    private static func started(_ advertisement: String?) throws -> RightyoInputEvent {
        let owner = advertisement.map { #""owner_voice": \#($0), "# } ?? ""
        return try line(#"""
            "type": "session", "phase": "started", \#(owner)"capabilities": {"activation": "finalized-turn",
             "partials": false, "speakers": "enrolled", "context": true}
            """#, sequence: 1)
    }

    private static func status(_ state: String) throws -> RightyoInputEvent {
        try line(#""type": "owner_voice", "state": "\#(state)""#)
    }

    @Test(arguments: ["unrecognized", "recognized"])
    func aWellFormedStatusValidates(_ state: String) throws {
        try Self.status(state).validate(session: "s", enrolled: true)
        try Self.started(#"{"threshold_s": 20}"#).validate(session: "s", enrolled: true)
    }

    @Test(arguments: [
        #""type": "owner_voice", "state": "tentative""#, #""type": "owner_voice""#,
        #""type": "owner_voice", "state": "unrecognized", "utterance_id": "u""#,
        #""type": "owner_voice", "state": "unrecognized", "reason": "x""#,
        #""type": "transcript", "owner_voice": {"threshold_s": 20}"#,
        #""type": "attention", "state": "unrecognized""#
    ])
    func anythingElseIsRefused(_ fields: String) throws {
        let event = try Self.line(fields)
        #expect(throws: RightyoInputError.invalidEvent) { try event.validate(session: "s", enrolled: true) }
    }

    private func reported(advertisement: String?, _ states: [String]) throws -> [String] {
        let seen = Mutex<[String]>([])
        let relay = AmbientOwnerVoiceRelay(onOwnerVoice: { state in seen.withLock { $0.append(state) } })
        relay.observe(try Self.started(advertisement))
        for state in states { relay.observe(try Self.status(state)) }
        return seen.withLock { $0 }
    }

    @Test func eachStateIsReportedOnceAndRecognizedOnlyAfterUnrecognized() throws {
        let states = ["recognized", "unrecognized", "unrecognized", "recognized", "recognized", "unrecognized"]
        #expect(try reported(advertisement: #"{"threshold_s": 20}"#, states) == ["unrecognized", "recognized"])
    }

    @Test(arguments: [nil, "false", "true", "{}", #"{"threshold_s": "20"}"#, #""yes""#])
    func withoutTheDocumentedAdvertisementNothingIsReported(_ advertisement: String?) throws {
        #expect(try reported(advertisement: advertisement, ["unrecognized"]).isEmpty)
    }

    @Test func theBaseEnvironmentStaysFixedAndTheRouteListMatchesRightyO() throws {
        let base = RightyoChildProcess.environment(["HOME": "/home", "PATH": "/evil"])
        #expect(base["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(AmbientRightyoRouter.rightyoInputRoutes == Set(AmbientInput.routes))
    }

    /// A fake RightyO that advertises `owner_voice` and reports `unrecognized` only when haild opted it in and passed
    /// the route the device named.
    static let fixture = """
        /usr/bin/sed -e '$d' -e "s/tool-demo/$7/g" \
          -e 's/"phase": "started",/"owner_voice": {"threshold_s": 20}, "phase": "started",/' events.jsonl
        /bin/cat > /dev/null
        if [ "$RIGHTYO_OWNER_VOICE_EVENTS" = 1 ] && [ "$RIGHTYO_INPUT_ROUTE" = usb_audio ]; then
          printf '{"schema_version": 1, "type": "owner_voice", "session_id": "%s", "sequence": 7, ' "$7"
          printf '"emitted_at_ms": 2100, "state": "unrecognized"}\\n'
        fi
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e "s/tool-demo/$7/g" -e 's/"sequence": 7/"sequence": 8/'
        """

    /// Through the real listener: the device names its route, the child is opted in with it, and the status reaches
    /// a device that advertised `owner_voice_status`; an older device gets nothing, and the log says which.
    @Test(arguments: [true, false])
    func theStatusReachesOnlyACapableSpeakingDevice(capable: Bool) async throws {
        let fake = try FakeRightyo(Self.fixture)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let logged = Mutex<[String]>([])
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), onEvent: { event in
            if event.event == "ambient_owner_voice" { logged.withLock { $0.append(event.detail ?? "") } }
        })
        let pair = try await FallbackSocketPair.connect(
            port: env.port, selecting: [RecipientTestRig.target],
            capabilities: ["probe"] + (capable ? [OwnerVoice.capability] : [])
        )
        defer { pair.close() }
        let socket = pair.sockets[0]
        try await recipientSocketSend(sessionFrame(payload: .control(.ambientInput(route: "usb_audio"))), on: socket)
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: socket)
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        #expect(await eventually { logged.withLock { !$0.isEmpty } })
        #expect(logged.withLock { $0 } == ["state=unrecognized device=\(capable ? "sent" : "unsupported")"])
        if capable {
            #expect(try await receiveFrame(on: socket, step: "owner voice").payload
                == .control(.ownerVoice(state: "unrecognized")))
        }
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
    }
}
#endif
