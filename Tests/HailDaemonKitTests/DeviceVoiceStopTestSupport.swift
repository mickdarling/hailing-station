#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The child emits its session header, then waits for a file authored by the test before emitting its dismissal.
/// Every negative socket assertion follows a completed handler log and a ping/pong barrier, never a settling sleep.
struct DeviceVoiceStopRig {
    let fake: FakeRightyo
    let env: AmbientWiringRig
    let pair: FallbackSocketPair
    let observation: DeviceVoiceStopObservation

    var socket: URLSessionWebSocketTask { pair.sockets[0] }

    static func make(capabilities: [String] = [PlaybackStop.capability]) async throws -> Self {
        let owned = AmbientWiringStopConfirmationTests.fixture(dismiss: "owner", turn: "owner")
        let rest = owned.replacingOccurrences(of: "-e '$d'", with: "-e '1d;$d'")
        let script = """
            /usr/bin/head -1 events.jsonl | /usr/bin/sed -e "s/dismissal-demo/$7/g" \
              -e 's/"speakers": "anonymous"/"speakers": "enrolled"/'
            while [ ! -f release ]; do /bin/sleep 0.02; done
            \(rest)
            """
        let fake = try FakeRightyo(script)
        do {
            try fake.install(fixture: "dismissal-events.jsonl")
            let observation = DeviceVoiceStopObservation()
            let clips = AmbientAckLibrary(clips: [
                "confirmstopped": [AmbientWiringStopConfirmationTests.stopped],
                "confirmidle": [AmbientWiringStopConfirmationTests.idle]
            ])
            let env = try await ambientRig(fake, timing: .init(eofGrace: 2, termGrace: 2),
                                           acknowledgements: clips,
                                           onEvent: { event in observation.events.withLock { $0.append(event) } },
                                           voiceStopClock: { observation.clock.withLock { $0 } })
            do {
                let pair = try await FallbackSocketPair.boundedConnect(
                    port: env.port, selecting: [RecipientTestRig.target], capabilities: capabilities
                )
                return Self(fake: fake, env: env, pair: pair, observation: observation)
            } catch {
                await env.listener.stop(reason: "synthetic setup failure")
                throw error
            }
        } catch {
            fake.cleanUp()
            throw error
        }
    }

    func details(_ name: String) -> [String] {
        observation.events.withLock { $0.filter { $0.event == name }.map { $0.detail ?? "" } }
    }

    func advance(by seconds: Int) {
        observation.clock.withLock { $0 = $0.advanced(by: .seconds(seconds)) }
    }

    func start() async throws {
        try await recipientSocketSend(audio(UUID(), 0), on: socket)
        try #require(await eventually { env.router.activeConnection() != nil })
    }

    func report(latency: Int? = 42) async throws {
        try await recipientSocketSend(sessionFrame(payload: .control(.voiceStopped(latencyMs: latency))), on: socket)
    }

    func releaseDismissal() throws {
        try Data().write(to: fake.directory.appendingPathComponent("release"))
    }

    func finish() async {
        try? releaseDismissal()
        pair.close()
        await env.listener.stop(reason: "synthetic test complete")
        fake.cleanUp()
    }
}
final class DeviceVoiceStopObservation: Sendable {
    let events = Mutex<[WebSocketListenerEvent]>([])
    let clock = Mutex(ContinuousClock.now)
}
#endif
