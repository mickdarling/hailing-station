#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoPrivacyAdmissionTests {
    private static let confirmed = """
    /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
      -e 's/"phase"/"duck":{"version":3,"private":true},"request_outcomes":{"version":1},"phase"/'
    """
    private static let tail = """
    /bin/cat >> audio.raw
    /bin/cat <&3 >> control.txt
    /usr/bin/sed -n '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
    """

    enum AfterStartup: CaseIterable, Sendable { case deliver, full, superseded }

    @Test(arguments: AfterStartup.allCases)
    func offAtLaunchGetsItsDeliveryWindowAfterConfirmation(_ outcome: AfterStartup) async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake(Self.confirmed + "\n" + Self.tail)
        defer { fake.cleanUp() }
        let timer = ManualPrivacyTimer()
        let pipeline = try AmbientPrivacyAudioGateTests.pipeline(fake, startPrivate: true, configure: {
            $0.privacyRetryClock = timer.clock
        })
        var mediaLines = 0
        if outcome == .full { while pipeline.reportMedia(true) { mediaLines += 1 } }
        let results = Mutex<[Bool]>([])
        #expect(!pipeline.reportDuck(false) { result in results.withLock { $0.append(result) } })
        #expect(timer.advance(to: 500))
        #expect(results.withLock { $0.isEmpty } && !pipeline.hearsAudio)
        if outcome == .superseded { #expect(pipeline.reportDuck(true)) }
        _ = timer.advance(to: 600)
        let run = Task { try await pipeline.run() }
        #expect(await pipeline.privacyKept())
        _ = timer.advance(to: 605)
        if outcome == .full {
            #expect(timer.advance(to: 1_099))
            #expect(results.withLock { $0.isEmpty })
            #expect(timer.advance(to: 1_100))
        }
        #expect(results.withLock { $0 } == [outcome == .deliver])
        #expect(pipeline.privacyControl.active == (outcome != .deliver))
        #expect((pipeline.requestOutcomes.generation != nil) == (outcome == .deliver))
        pipeline.finishInput()
        _ = try await run.value
        let expected = String(repeating: "{\"media\":true}\n", count: mediaLines)
            + (outcome == .deliver ? "{\"duck\":false}\n" : "")
        #expect(try fake.recorded("control.txt") == expected)
    }

    private static let heldControl = """
        \(RightyoPrivacyAdmissionTests.confirmed)
        /bin/dd bs=3200 count=1 > audio.raw 2>/dev/null
        \(AmbientPrivacyEventTests.line("status", sequence: 2, at: 0))
        read -r release < release
        /bin/dd bs=15 count=1 <&3 > control.txt 2>/dev/null
        \(AmbientPrivacyEventTests.line("status", sequence: 3, at: 0))
        \(RightyoPrivacyAdmissionTests.tail)
        """

    @Test func publicGapIsAdmittedBeforeOffDelivery() async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake(Self.heldControl)
        defer { fake.cleanUp() }
        try #require(mkfifo(fake.directory.appendingPathComponent("release").path, 0o600) == 0)
        let gapClock = AmbientGapTestClock(), timer = ManualPrivacyTimer()
        let (status, signal) = AsyncStream<Bool>.makeStream()
        let pipeline = try AmbientPrivacyAudioGateTests.pipeline(fake, startPrivate: true,
                                                                gapClock: { gapClock.now }, configure: {
            $0.privacyRetryClock = timer.clock
            $0.onVoiceDuck = { if $0 == .status { signal.yield(true) } }
        })
        let run = Task {
            defer { signal.finish() }
            return try await pipeline.run()
        }
        #expect(await pipeline.privacyKept())
        let first = AmbientGapFillRig.chunk(0), second = AmbientGapFillRig.chunk(2)
        #expect(pipeline.send(audio: first, sequence: 0).accepted)
        var events = status.makeAsyncIterator()
        try #require(await events.next() == true)
        var mediaLines = 0
        while pipeline.reportMedia(true) { mediaLines += 1 }
        let results = Mutex<[Bool]>([])
        #expect(!pipeline.reportDuck(false) { result in results.withLock { $0.append(result) } })
        gapClock.advance(.milliseconds(200))
        let frame = pipeline.send(audio: second, sequence: 2)
        #expect(frame.accepted && frame.gap?.bytes == 3_200)
        #expect(results.withLock { $0.isEmpty } && pipeline.requestOutcomes.generation == nil)
        try await releaseStopMuteFixture(fake)
        try #require(await events.next() == true)
        #expect(timer.advance(to: 5))
        #expect(results.withLock { $0 } == [true])
        pipeline.finishInput()
        _ = try await run.value
        #expect(AmbientPrivacyAudioGateTests.heard(fake) == first + AmbientGapFillRig.silence(1) + second)
        let expected = String(repeating: "{\"media\":true}\n", count: mediaLines) + "{\"duck\":false}\n"
        #expect(try fake.recorded("control.txt") == expected)
    }
}
#endif
