#if os(macOS)
import Foundation
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

    @Test func fullPipeRetriesAndKeepsBothPrivacyGatesClosed() async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake("""
        /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/"phase"/"duck":{"version":3,"private":true},"request_outcomes":{"version":1},"phase"/'
        /bin/cat > /dev/null
        /usr/bin/sed -n '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """)
        defer { fake.cleanUp() }
        let pipeline = try AmbientPrivacyAudioGateTests.pipeline(fake, startPrivate: true)
        let run = Task { try await pipeline.run() }
        #expect(await pipeline.privacyKept())
        #expect(pipeline.requestOutcomes.supported)
        // Media-on and privacy-off occupy the same number of bytes. The reader stays open and idle.
        while pipeline.reportMedia(true) {}
        let change = pipeline.reservePrivacyOff(through: nil)
        #expect(change.attempt(false) == .pending)
        #expect(change.attempt(false) == .pending)
        #expect(change.attempt(true) == .failed)
        #expect(pipeline.privacyControl.active)
        #expect(pipeline.requestOutcomes.generation == nil)
        pipeline.finishInput()
        _ = try await run.value
    }
}
#endif
