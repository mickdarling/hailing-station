#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

struct AmbientBoundaryRig {
    let fake: FakeRightyo
    let env: AmbientWiringRig
    let pair: FallbackSocketPair
    let connection: UUID
    let events: DuckEvents
    let clock: AmbientGapTestClock
    let stream = UUID()
    var router: AmbientRightyoRouter { env.router }

    typealias Lines = RightyoPrivacyLossRegressionTests

    static let prefix = Data([17, 17]), marker = Data([191, 191]), later = Data([73, 73])

    static func child(positioned: Bool = true, beforeStarted: String = "", record: String? = nil) -> String {
        """
        printf '%s\\n' "$@" > "$7.argv"
        \(beforeStarted)
        case " $* " in
          *" --start-private "*) \(Lines.started(privateLaunch: true, positioned: positioned));;
          *) \(Lines.started(privateLaunch: false, positioned: positioned));;
        esac
        \(record ?? controlAndAudio)
        \(RightyoPrivacyLossRegressionTests.stopped)\(FakeRightyo.lastSequence)
        """
    }

    static let acknowledge = AmbientPrivacyEventTests.line("on", sequence: 2, at: 0, extra: #", \"at_ms\": 0"#)
    private static let controlAndAudio = """
        : > "$7.control"
        (
          while IFS= read -r line <&3; do
            echo "$line" >> "$7.control"
            if [ "$line" = '{"duck":true}' ]; then
              \(acknowledge)
            fi
          done
        ) &
        /bin/cat > "$7.raw"
        wait
        """

    static func withRig(script: String = child(), childMade: (@Sendable (UUID) -> Void)? = nil,
                        _ exercise: (Self) async throws -> Void) async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake(script)
        defer { fake.cleanUp() }
        let clock = AmbientGapTestClock(), events = DuckEvents()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 2), replyControl: true,
                                       startDeadline: DuckRig.deadline, ackDeadline: DuckRig.deadline,
                                       onEvent: { event in events.list.withLock { $0.append(event) } },
                                       childMade: childMade, gapClock: { clock.now })
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target],
                                                                   capabilities: [DuckMode.capability])
            defer { pair.close() }
            let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
            try await exercise(Self(fake: fake, env: env, pair: pair, connection: connection,
                                    events: events, clock: clock))
        } catch {
            await env.listener.stop()
            throw error
        }
        await env.listener.stop()
    }

    func start(_ id: UUID? = nil, on owner: UUID? = nil) {
        router.ambientAudio(.admittedStart(stream: id ?? stream, connection: owner ?? connection,
                                           target: RecipientTestRig.target, binding: "reply-binding",
                                           policy: env.admissionPolicy))
    }

    func send(_ bytes: Data, _ sequence: Int, on id: UUID? = nil) {
        router.ambientAudio(.segment(stream: id ?? stream, sequence: sequence, bytes: bytes))
    }

    func active() throws -> RightyoAmbientPipeline { try #require(router.activePipeline) }

    func enter() async throws {
        let child = try active()
        try #require(await eventually { child.childStarted })
        router.ambientPrivacy(true, connection: connection)
        try #require(await child.privacyKept())
    }

    func off() { router.ambientPrivacy(false, connection: connection) }

    func end(_ id: UUID? = nil) async throws -> Data {
        let (child, task) = try router.state.withLock { state in
            let active = try #require(state.active)
            try #require(active.stream == (id ?? stream))
            return (active.pipeline, try #require(state.runs[active.run]?.task))
        }
        router.ambientAudio(.ended(stream: id ?? stream, reason: .final))
        await task.value
        return try Data(contentsOf: fake.directory.appendingPathComponent(child.session + ".raw"))
    }

    func arguments(_ child: RightyoAmbientPipeline) throws -> [Substring] {
        try fake.recorded(child.session + ".argv").split(separator: "\n")
    }

    func controls(_ child: RightyoAmbientPipeline) throws -> String {
        try fake.recorded(child.session + ".control")
    }
}
#endif
