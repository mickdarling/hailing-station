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

    static func make(
        capabilities: [String] = [PlaybackStop.capability], hold: VoiceStopConfirmationHold? = nil,
        ambientWired: Bool = true
    ) async throws -> Self {
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
                                           acknowledgementHold: hold.map { barrier in .init { await barrier.wait() } },
                                           onEvent: { event in observation.events.withLock { $0.append(event) } },
                                           ambientWired: ambientWired,
                                           voiceStopClock: { observation.clock.withLock { $0 } },
                                           onListenerEvent: { event in
                                               observation.events.withLock { $0.append(event) }
                                           })
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
        try await start(on: socket)
    }

    func start(on socket: URLSessionWebSocketTask, replacing previous: UUID? = nil) async throws {
        try await recipientSocketSend(audio(UUID(), 0), on: socket)
        try #require(await eventually {
            guard let current = env.router.activeConnection() else { return false }
            return current != previous
        })
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

/// Continuation-based delivery barrier; release also works before entry and cleanup never blocks a Swift worker.
final class VoiceStopConfirmationHold: Sendable {
    private struct State {
        var waiting: CheckedContinuation<Void, Never>?
        var entered = false
        var released = false
    }
    private let state = Mutex(State())
    var entered: Bool { state.withLock { $0.entered } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state in
                state.entered = true
                if state.released { return true }
                state.waiting = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func release() {
        let waiting = state.withLock { state in
            state.released = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume()
    }
}
#endif
