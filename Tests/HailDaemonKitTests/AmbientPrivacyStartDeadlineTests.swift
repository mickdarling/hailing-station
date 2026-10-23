#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// The start-private deadline and refusal (#735 S-2b round 3, key 2's mutation gaps): a confirmed child outlives the
/// deadline, an expired start is always a refusal, privacy ended during startup is written off, and a refused child
/// is stopped with no grace. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyStartDeadlineTests {
    private typealias Gate = AmbientPrivacyAudioGateTests

    /// D2: a confirmed start-private child keeps running past its deadline; the deadline only ends a wait for `started`.
    @Test func aConfirmedChildOutlivesTheDeadline() async throws {
        let fake = try Gate.fake(Gate.script(advertises: true, delay: "0"))
        defer { fake.cleanUp() }
        // A 3 s deadline: a cold script launch at background priority (`taskpolicy -b`, #821) can take over a second,
        // and the confirm must land before it. The wait after it still runs past the deadline.
        let pipeline = try Gate.pipeline(fake, startPrivate: true, deadline: 3)
        let run = Task { try await pipeline.run() }
        #expect(await eventually { pipeline.hearsAudio })
        try await Task.sleep(for: .milliseconds(3_500))
        #expect(pipeline.send(audio: Gate.chunk(0x55)))
        pipeline.finishInput()
        _ = try await run.value
        #expect(await eventually { Gate.heard(fake).contains(0x55) })
    }

    /// D3: once the deadline has expired, the run is a refusal however it ends, a clean end included.
    @Test func anExpiredStartIsARefusalEvenWhenTheRunEndsCleanly() throws {
        let expired = AmbientDuckControl(startPrivate: true)
        #expect(expired.expire() && expired.expired)
        #expect(throws: RightyoPrivacyRefusal.unconfirmedStart) { try expired.checkStarted() }
        let started = AmbientDuckControl(startPrivate: true), written = AmbientDuckControlTests.Written()
        _ = started.observe(started: Data(AmbientPrivacyStartPrivateTests.confirmed.utf8), write: written.write)
        #expect(!started.expire())
        try started.checkStarted()
    }

    /// MD2: a child confirmed private whose privacy ended during its startup is written `{"duck":false}`, so it never
    /// stays private while the host is public.
    @Test func aConfirmedChildWhosePrivacyEndedIsWrittenOff() async throws {
        let fake = try Gate.fake(Gate.script(advertises: true))
        defer { fake.cleanUp() }
        let pipeline = try Gate.pipeline(fake, startPrivate: true)
        let run = Task { try await pipeline.run() }
        _ = pipeline.reportDuck(false)
        #expect(await eventually { (try? fake.recorded("control.txt")) == "{\"duck\":false}\n" })
        pipeline.finishInput()
        _ = try await run.value
    }

    /// M13: a refused child is stopped with no grace: one that ignores SIGTERM and never reads EOF is still gone at
    /// once, not after the 20 s graces this pipeline was given.
    @Test func aRefusedChildIsStoppedWithNoGrace() async throws {
        let fake = try Gate.fake("""
        trap '' TERM
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g"
        while :; do /bin/sleep 1; done
        """)
        defer { fake.cleanUp() }
        let pipeline = try Gate.pipeline(fake, startPrivate: true)
        let started = ContinuousClock.now
        await #expect(throws: RightyoPrivacyRefusal.unconfirmedStart) { _ = try await pipeline.run() }
        #expect(started.duration(to: .now) < .seconds(8))
    }
}
#endif
