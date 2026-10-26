#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Refuses its first dispatches with the given refusals, then hands every later one off; records them all.
actor PendingInputDispatcher: RightyoAmbientDispatching {
    private(set) var requests: [LocalDispatchRequest] = []
    private var refusals: [LocalDispatchRefusal]

    init(refusing refusals: [LocalDispatchRefusal]) { self.refusals = refusals }

    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        requests.append(request)
        if !refusals.isEmpty { throw refusals.removeFirst() }
        return UUID()
    }
}

/// What one pipeline's hooks were told.
final class PendingInputHooks: Sendable {
    let refused = Mutex<[LocalDispatchRefusal]>([])
    let acks = Mutex(0)
    var refusals: [LocalDispatchRefusal] { refused.withLock { $0 } }
}

/// #894 ask 3 in the pipeline: a request the target refused for pending input is handed to `onDeliveryRefused` once,
/// with its refusal, and the child lives on to deliver the next one. Any other refusal still ends the stream. Synthetic
/// child and dispatcher only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoAmbientPendingInputTests {
    /// The canonical fixture's request, then the same request under new ids (`again`), each held until the test writes
    /// a file (`go1`, `go2`); the session stops once stdin closes.
    static let twoRequests = #"""
        /usr/bin/sed -n -e '1,3p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        while [ ! -f go1 ]; do /bin/sleep 0.02; done
        /usr/bin/sed -n -e '4,6p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        while [ ! -f go2 ]; do /bin/sleep 0.02; done
        /usr/bin/sed -n -e '4,6p' events.jsonl | /usr/bin/sed -e 's/"sequence": \([4-6]\),/"sequence": 1\1,/' \
            -e 's/"emitted_at_ms": 2000,/"emitted_at_ms": 2100,/' -e 's/tool-demo:request/tool-demo:again/' \
            -e 's/"utterance_id": "request"/"utterance_id": "again"/g' -e "s/tool-demo/$7/g"
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e 's/"sequence": 7,/"sequence": 17,/' -e "s/tool-demo/$7/g"
        """#

    static func release(_ fake: FakeRightyo, _ name: String) throws {
        try Data().write(to: fake.directory.appendingPathComponent(name))
    }

    func pipeline(
        _ fake: FakeRightyo, dispatcher: PendingInputDispatcher, hooks: PendingInputHooks
    ) throws -> RightyoAmbientPipeline {
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 0.5, termGrace: 2),
            onAcknowledge: { _ in hooks.acks.withLock { $0 += 1 } }
        )
        configuration.onDeliveryRefused = { refusal in hooks.refused.withLock { $0.append(refusal) } }
        return try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
    }

    /// One refused request, then one delivered; or both refused. Each refusal is told once, and the child, which only
    /// sends its second request after the first was refused, is never stopped.
    @Test(arguments: [1, 2])
    func pendingInputIsToldOncePerRequestAndTheChildLivesOn(_ refusing: Int) async throws {
        let fake = try FakeRightyo(Self.twoRequests)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let dispatcher = PendingInputDispatcher(refusing: Array(repeating: .inputPending, count: refusing))
        let hooks = PendingInputHooks()
        let pipeline = try pipeline(fake, dispatcher: dispatcher, hooks: hooks)
        let run = Task { try await pipeline.run() }
        try Self.release(fake, "go1")
        #expect(await eventually { hooks.refusals == [.inputPending] })
        #expect(pipeline.send(audio: Data(repeating: 3, count: 3_200)), "the child still takes audio")
        try Self.release(fake, "go2")
        #expect(await eventually { await dispatcher.requests.count == 2 })
        pipeline.finishInput()
        let summary = try await run.value
        #expect(summary.delivered == 2 - refusing)
        #expect(summary.exit == .exited(0))
        #expect(hooks.refusals == Array(repeating: .inputPending, count: refusing))
        // Un-routed requests are acknowledged before they are typed (out of scope here): the ack still comes first.
        #expect(hooks.acks.withLock { $0 } == 2)
    }

    /// Any other refusal of the stream's own target still ends the stream and stops the child, told to nobody here.
    @Test func anotherRefusalStillEndsTheStreamAndStopsTheChild() async throws {
        let fake = try FakeRightyo(Self.twoRequests)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let dispatcher = PendingInputDispatcher(refusing: [.deliveryRefused])
        let hooks = PendingInputHooks()
        let pipeline = try pipeline(fake, dispatcher: dispatcher, hooks: hooks)
        try Self.release(fake, "go1")
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) { try await pipeline.run() }
        #expect(hooks.refusals.isEmpty)
        #expect(await dispatcher.requests.count == 1)
        #expect(!pipeline.send(audio: Data(repeating: 3, count: 3_200)), "the child was stopped")
    }
}
#endif
