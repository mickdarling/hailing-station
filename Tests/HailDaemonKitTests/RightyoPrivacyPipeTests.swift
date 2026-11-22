#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoPrivacyPipeTests {
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
