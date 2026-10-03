#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// Stands in for `WebSocketListener.dispatch(_:)` (#203, PR 3).
actor RecordingAmbientDispatcher: RightyoAmbientDispatching {
    private(set) var requests: [LocalDispatchRequest] = []
    private let owner: UUID?
    private let refusal: LocalDispatchRefusal?

    init(owner: UUID? = UUID(), refusal: LocalDispatchRefusal? = nil) {
        (self.owner, self.refusal) = (owner, refusal)
    }

    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        requests.append(request)
        if let refusal { throw refusal }
        return owner
    }
}

@Suite(.timeLimit(.minutes(1))) struct RightyoAmbientPipelineTests {
    /// Echoes the canonical fixture under the session it was given, counts stdin to EOF, then emits `stopped`,
    /// as `rightyo listen --mode stdin` does. Argument 7 is the session id in the fixed argv.
    static let echoFixture = """
        printf '%s\\n' "$@" > argv.txt
        /usr/bin/sed -e '$d' -e "s/tool-demo/$7/g" events.jsonl
        /usr/bin/wc -c | /usr/bin/tr -d ' ' > stdin-bytes.txt
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        """

    func pipeline(_ fake: FakeRightyo, dispatcher: RecordingAmbientDispatcher,
                  connection: UUID = UUID()) throws -> RightyoAmbientPipeline {
        try RightyoAmbientPipeline(configuration: .init(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: connection, allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        ), dispatcher: dispatcher)
    }

    @Test func admittedRequestsReachTheDispatcherForTheNamedConnection() async throws {
        let fake = try FakeRightyo(Self.echoFixture)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let dispatcher = RecordingAmbientDispatcher()
        let connection = UUID()
        let pipeline = try pipeline(fake, dispatcher: dispatcher, connection: connection)
        #expect(pipeline.session.hasPrefix("hail-"))
        #expect(UUID(uuidString: String(pipeline.session.dropFirst(5))) != nil)
        for _ in 0..<5 { #expect(pipeline.send(audio: Data(repeating: 3, count: 3_200))) }
        pipeline.finishInput()
        let summary = try await pipeline.run()
        #expect(summary.delivered == 1)
        #expect(summary.exit == .exited(0))
        #expect(summary.child.writtenBytes == 16_000)
        #expect(try fake.recorded("stdin-bytes.txt") == "16000\n")
        let argv = try fake.recorded("argv.txt").split(separator: "\n").map(String.init)
        #expect(argv == ["listen", "--mode", "stdin", "--provenance", "live-microphone",
                         "--session-id", pipeline.session, "--config", fake.config.path])
        let requests = await dispatcher.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.connection == connection)
        #expect(request.target == "tmux:demo")
        #expect(request.binding == "pinned")
        #expect(request.text.contains("haild reply"))
    }

    @Test func aConsumerErrorEndsTheStreamAndStopsTheChild() async throws {
        // The fixture keeps its own session id, so the first event is refused; the child would otherwise idle.
        let fake = try FakeRightyo("/bin/cat events.jsonl\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: .init(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 0.5, termGrace: 20)
        ), dispatcher: dispatcher)
        await #expect(throws: RightyoInputError.invalidEvent) { try await pipeline.run() }
        #expect(await dispatcher.requests.isEmpty)
        #expect(!pipeline.send(audio: Data(repeating: 0, count: 2)))
    }

    @Test func liveMicrophoneProvenanceIsRequiredByDefault() async throws {
        let fake = try FakeRightyo(Self.echoFixture)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: .init(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), timing: .init(eofGrace: 20, termGrace: 20)
        ), dispatcher: dispatcher)
        pipeline.finishInput()
        await #expect(throws: RightyoInputError.invalidEvent) { try await pipeline.run() }
        #expect(await dispatcher.requests.isEmpty)
    }

    @Test func aHandedOffRefusalIsAReceiptAndOtherRefusalsEndTheStream() async throws {
        let step = { (refusal: LocalDispatchRefusal) in
            RightyoAmbientDispatchStep(connection: UUID(), dispatcher: RecordingAmbientDispatcher(refusal: refusal))
        }
        let receipt = try await step(.ownershipLost).dispatch(text: "hi", target: "tmux:demo", binding: "pinned")
        #expect(receipt == RightyoDispatchReceipt(request: nil, caveat: LocalDispatchRefusal.ownershipLost.message))
        await #expect(throws: LocalDispatchRefusal.selectionChanged) {
            try await step(.selectionChanged).dispatch(text: "hi", target: "tmux:demo", binding: "pinned")
        }
        await #expect(throws: RightyoInputError.capacity) {
            try await step(.ownershipLost).dispatch(text: String(repeating: "a", count: 8 * 1024 + 1),
                                                    target: "tmux:demo", binding: "pinned")
        }
    }

    @Test func anUnsafeTargetOrExecutableLaunchesNothing() throws {
        let fake = try FakeRightyo("echo launched > launched.txt", mode: 0o775)
        defer { fake.cleanUp() }
        let configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID())
        #expect(throws: RightyoChildError.unsafeExecutable) {
            try RightyoAmbientPipeline(configuration: configuration, dispatcher: RecordingAmbientDispatcher())
        }
        var unsafeTarget = configuration
        unsafeTarget.target = "tmux:a b"
        #expect(throws: RightyoTargetError.unsafeIdentifier) {
            try RightyoAmbientPipeline(configuration: unsafeTarget, dispatcher: RecordingAmbientDispatcher())
        }
        #expect(!FileManager.default.fileExists(atPath: fake.directory.appendingPathComponent("launched.txt").path))
    }
}
#endif
