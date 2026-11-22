#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

private final class ResumeRetry: Sendable {
    typealias Tick = @Sendable (Bool) -> Void
    private let next = Mutex<Tick?>(nil)

    func schedule(_ tick: @escaping Tick) { next.withLock { $0 = tick } }

    func fire(expired: Bool) throws {
        let tick = next.withLock { value in
            defer { value = nil }
            return value
        }
        let action = try #require(tick)
        action(expired)
    }
}

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyResumeOrderingTests {
    private typealias Resume = AmbientRightyoRouter.PrivacyResume
    private let marker = Data([191, 191]), later = Data([73, 73])

    /// The child acknowledges entry and keeps fd 3 open without reading further controls.
    private func privateRig() async throws -> DuckRig {
        let started = AsyncStream<Void>.makeStream()
        let ack = AmbientPrivacyEventTests.line("on", sequence: 3, at: 0, extra: #", \"at_ms\": 0"#)
        let rig = try await DuckRig(script: """
        /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \(AmbientPrivacyEventTests.duck(3))
        \(AmbientPrivacyEventTests.line("status", sequence: 2, at: 0))
        IFS= read -r entry <&3
        \(ack)
        /bin/cat > audio.raw
        /bin/cat <&3 > control.txt
        /usr/bin/sed -n '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """, clips: AmbientDuckModeTests.clips, capabilities: [DuckMode.capability], onEvent: { event in
            if event.event == "ambient_duck_confirmed", event.detail == AmbientPrivacySwitchTests.statusOff {
                started.continuation.finish()
            }
        })
        for await _ in started.stream {}
        try await AmbientPrivacySwitchTests.send(true, on: rig.socket)
        let (_, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "entry")
        try #require(words == "Privacy on. I'm only listening for my name.")
        return rig
    }

    /// Drain both output chains, then use a protocol pong as the on-wire fence for negative assertions.
    private func expectPrivate(_ rig: DuckRig, connection: UUID, reasserted: Bool = false) async throws {
        let router = rig.env.router
        await router.mediaNotices.queued {}.value
        let clips = router.state.withLock { AmbientRightyoRouter.clipChain(connection, in: &$0) }
        await clips.queued {}.value
        let frames = try await AmbientPrivacySwitchTests.untilPong(rig.socket, step: "private")
        if reasserted { #expect(frames.contains(.control(.duckMode(on: true, reason: "device")))) }
        for frame in frames {
            if case .control(.duckMode(false, _, _)) = frame { Issue.record("Unexpected resume notice") }
            if case .text(let text) = frame { #expect(text.text != "Recording again.") }
        }
        #expect(router.duckMode(connection: connection))
        #expect(router.activePipeline?.privacyControl.active == true)
    }

    private static func requestOff(_ rig: DuckRig, connection: UUID, retry: ResumeRetry) {
        Resume.$retry.withValue(retry.schedule) {
            rig.env.router.ambientPrivacy(false, connection: connection)
        }
    }

    @Test(arguments: [false, true])
    func queuedSegmentAndDeviceConfirmationWaitForDelivery(fullPipe: Bool) async throws {
        let rig = try await privateRig()
        defer { rig.close() }
        let router = rig.env.router, retry = ResumeRetry()
        let connection = try #require(rig.connection())
        let pipeline = try #require(router.activePipeline)
        if fullPipe { while pipeline.reportMedia(true) {} }
        router.state.withLock { $0.reloading = true }
        defer { router.state.withLock { $0.reloading = false } }
        router.ambientAudio(.segment(stream: rig.stream, sequence: 1, bytes: marker))
        try #require(router.state.withLock { !$0.queue.isEmpty })
        Self.requestOff(rig, connection: connection, retry: retry)
        try await expectPrivate(rig, connection: connection, reasserted: true)
        try retry.fire(expired: false)
        try await expectPrivate(rig, connection: connection)
        try retry.fire(expired: true)
        if fullPipe {
            try await expectPrivate(rig, connection: connection)
        } else {
            let (frames, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "delivered")
            #expect(frames.contains(.control(.duckMode(on: false, reason: "device"))))
            #expect(words == "Recording again.")
        }
        router.state.withLock { $0.reloading = false }
        await finishInput(rig)
        let heard = AmbientPrivacyAudioGateTests.heard(rig.fake)
        let controls = try rig.fake.recorded("control.txt")
        #expect(controls.contains("{\"duck\":false}\n") == !fullPipe)
        #expect(heard.range(of: marker) == nil)
        #expect(heard.range(of: later) != nil)
    }

    @Test func selectedChildCannotWriteAnExpiredInFlightSegment() async throws {
        let rig = try await privateRig()
        defer { rig.close() }
        let router = rig.env.router, retry = ResumeRetry()
        let connection = try #require(rig.connection())
        Resume.$beforeHandoff.withValue({
            Self.requestOff(rig, connection: connection, retry: retry)
            #expect(router.duckMode(connection: connection))
            do { try retry.fire(expired: true) } catch { Issue.record(error) }
        }, operation: {
            router.ambientAudio(.segment(stream: rig.stream, sequence: 1, bytes: marker))
        })
        #expect(!router.duckMode(connection: connection))
        await finishInput(rig)
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":false}\n")
        let heard = AmbientPrivacyAudioGateTests.heard(rig.fake)
        #expect(heard.range(of: marker) == nil)
        #expect(heard.range(of: later) != nil)
    }

    private func finishInput(_ rig: DuckRig) async {
        let router = rig.env.router
        router.ambientAudio(.segment(stream: rig.stream, sequence: 2, bytes: later))
        router.ambientAudio(.ended(stream: rig.stream, reason: .final))
        await rig.settle()
        await rig.env.listener.stop(reason: "synthetic test complete")
    }
}
#endif
