#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoPrivacyPipeTests {
    @Test(arguments: [false, true]) func withdrawingAPublicStartupWishRequiresDelivery(full: Bool) async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake("""
        /bin/cat > audio.raw
        /bin/cat <&3 > control.txt
        /usr/bin/sed -n -e '1p' -e '$p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g"\(FakeRightyo.duckV3)
        """)
        defer { fake.cleanUp() }
        let pipeline = try AmbientPrivacyAudioGateTests.pipeline(fake, startPrivate: false)
        #expect(pipeline.reportDuck(true) && !pipeline.hearsAudio)
        #expect(pipeline.send(audio: Data([1, 2])))
        var mediaLines = 0
        if full {
            while pipeline.reportMedia(true) { mediaLines += 1 }
            let change = pipeline.reservePrivacyOff(through: nil)
            #expect(change.attempt(false) == .pending)
            #expect(change.attempt(true) == .failed)
        } else {
            #expect(pipeline.reportDuck(false))
        }
        #expect(!pipeline.childStarted && pipeline.hearsAudio == !full)
        #expect(pipeline.send(audio: Data([3, 4])))
        pipeline.finishInput()
        _ = try await pipeline.run()
        let expected = String(repeating: "{\"media\":true}\n", count: mediaLines) + (full ? "" : "{\"duck\":false}\n")
        #expect(try fake.recorded("control.txt") == expected)
        let audio = try Data(contentsOf: fake.directory.appendingPathComponent("audio.raw"))
        #expect(audio == (full ? Data() : Data([3, 4])))
    }

    @Test func suppressedHandoffCompletesThePrefixWithoutConsumingTheBound() async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake("""
        /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/"phase"/"duck":{"version":3,"private":true},"phase"/'
        /bin/cat > /dev/null
        /usr/bin/sed -n '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """)
        defer { fake.cleanUp() }
        let pipeline = try AmbientPrivacyAudioGateTests.pipeline(fake, startPrivate: true)
        let change = pipeline.reservePrivacyOff(through: 7)
        #expect(pipeline.send(audio: Data([1, 1]), sequence: 7, admission: 7).accepted)
        let run = Task { try await pipeline.run() }
        #expect(await pipeline.privacyKept())
        #expect(change.attempt(false) == .delivered)
        #expect(pipeline.counters.writtenBytes == 0)
        pipeline.finishInput()
        _ = try await run.value
    }

    @Test func refusedPublicEntryRollsBackBothGates() async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake("""
        /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/"phase"/"duck":{"version":2},"request_outcomes":{"version":1},"phase"/'
        \(AmbientPrivacyEventTests.line("status", sequence: 2, at: 0))
        /bin/cat > audio.raw
        /bin/cat <&3 > control.txt
        /usr/bin/sed -n '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """)
        defer { fake.cleanUp() }
        let (ready, signal) = AsyncStream<Bool>.makeStream()
        let pipeline = try AmbientPrivacyAudioGateTests.pipeline(fake, startPrivate: false, configure: { settings in
            settings.onVoiceDuck = { if $0 == .status { signal.yield(true) } }
        })
        defer { pipeline.finishInput() }
        let run = Task {
            defer { signal.finish() }
            return try await pipeline.run()
        }
        var started = ready.makeAsyncIterator()
        try #require(await started.next() == true)
        let previous = try #require(pipeline.requestOutcomes.generation)
        #expect(!pipeline.reportDuck(true))
        #expect(!pipeline.hearsAudio && pipeline.requestOutcomes.generation == nil)
        #expect(pipeline.send(audio: Data([1, 2])))
        #expect(!pipeline.reportDuck(false))
        #expect(pipeline.hearsAudio)
        let resumed = pipeline.requestOutcomes.generation
        #expect(resumed != nil && resumed != previous)
        let pcm = Data([3, 4])
        #expect(pipeline.send(audio: pcm))
        pipeline.finishInput()
        _ = try await run.value
        #expect(AmbientPrivacyAudioGateTests.heard(fake) == pcm)
        #expect(try fake.recorded("control.txt").isEmpty)
    }

    @Test func fullPipeRetriesAndKeepsBothPrivacyGatesClosed() async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake("""
        /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/"phase"/"duck":{"version":3,"private":true},"request_outcomes":{"version":1},"phase"/'
        /bin/cat > /dev/null
        /bin/cat <&3 > control.txt
        /usr/bin/sed -n '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """)
        defer { fake.cleanUp() }
        let timer = ManualPrivacyTimer()
        let pipeline = try AmbientPrivacyAudioGateTests.pipeline(fake, startPrivate: true, configure: {
            $0.privacyRetryClock = timer.clock
        })
        let run = Task { try await pipeline.run() }
        #expect(await pipeline.privacyKept())
        #expect(pipeline.requestOutcomes.supported)
        // Media-on and privacy-off occupy the same number of bytes. The reader stays open and idle.
        var mediaLines = 0
        while pipeline.reportMedia(true) { mediaLines += 1 }
        let results = Mutex<[Bool]>([])
        #expect(!pipeline.reportDuck(false) { delivered in results.withLock { $0.append(delivered) } })
        #expect(results.withLock { $0.isEmpty })
        #expect(timer.advance(to: 499))
        #expect(results.withLock { $0.isEmpty })
        #expect(pipeline.privacyControl.active && pipeline.requestOutcomes.generation == nil)
        #expect(timer.advance(to: 500))
        #expect(!timer.advance(to: 505))
        #expect(results.withLock { $0 } == [false])
        #expect(pipeline.privacyControl.active)
        #expect(pipeline.requestOutcomes.generation == nil)
        pipeline.finishInput()
        _ = try await run.value
        #expect(try fake.recorded("control.txt") == String(repeating: "{\"media\":true}\n", count: mediaLines))
    }
}

private final class ManualPrivacyTimer: Sendable {
    private struct State {
        var now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        var scheduled: (DispatchTime, @Sendable () -> Void)?
    }
    private let state = Mutex(State())
    var clock: RightyoPrivacyOff.Clock {
        .init(now: { self.state.withLock { $0.now } }, schedule: { deadline, work in
            self.state.withLock { $0.scheduled = (deadline, work) }
        })
    }

    func advance(to milliseconds: Int) -> Bool {
        let work = state.withLock { state -> (@Sendable () -> Void)? in
            state.now = DispatchTime(uptimeNanoseconds: 1_000_000_000) + .milliseconds(milliseconds)
            guard let (deadline, work) = state.scheduled, deadline <= state.now else { return nil }
            state.scheduled = nil
            return work
        }
        guard let work else { return false }
        work()
        return true
    }
}
#endif
