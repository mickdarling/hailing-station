#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoPrivacyWithdrawalTests {
    @Test func rollbackAfterRefusedOnAcceptsOutcomes() throws {
        let started = try RightyoRequestOutcomeTests().started()
        let outcomes = AmbientRequestOutcomes(session: started.sessionId)
        outcomes.observe(started)
        let duck = AmbientDuckControl(setPrivate: outcomes.setPrivate), lines = AmbientDuckControlTests.Written()
        #expect(duck.observe(started: Data(AmbientDuckControlTests.started.utf8), write: lines.write) == .kept)
        #expect(!duck.report(true, write: lines.write))
        #expect(duck.active && outcomes.generation == nil)
        #expect(!duck.report(false, write: lines.write))
        #expect(!duck.active && lines.all.isEmpty)
        let host = UUID()
        try #require(outcomes.register(host: host, producer: "\(started.sessionId):request"))
        #expect(outcomes.report(.accepted, host: host, write: { $0.line != nil }))
    }

    @Test(arguments: [false, true]) func unsupportedStartUsesRouterPrivacy(stillPrivate: Bool) async throws {
        let fake = try AmbientPrivacyAudioGateTests.fake("""
        /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/"phase"/"request_outcomes":{"version":1},"phase"/'
        /bin/cat >/dev/null
        \(RightyoPrivacyLossRegressionTests.stopped)
        """)
        defer { fake.cleanUp() }
        let pipeline = try RightyoPrivacyLossRegressionTests.pipeline(fake, privateLaunch: false) {
            $0.onDuckUnsupported = { stillPrivate }
        }
        #expect(pipeline.reportDuck(true))
        let run = Task { try await pipeline.run() }
        let answer = await pipeline.privacyAnswer()
        #expect(pipeline.privacyControl.active == stillPrivate)
        #expect((pipeline.requestOutcomes.generation == nil) == stillPrivate)
        pipeline.finishInput()
        if stillPrivate {
            #expect(answer == .refused(.unsupportedChild))
            await #expect(throws: RightyoPrivacyRefusal.unsupportedChild) { _ = try await run.value }
        } else {
            #expect(answer == .withdrawn)
            _ = try await run.value
        }
    }

    @Test(arguments: [AmbientDuckControlTests.started, AmbientDuckControlTests.advertised])
    func withdrawalBeforePublicStartupWritesNothing(started: String) {
        let host = Mutex<[Bool]>([]), lines = AmbientDuckControlTests.Written()
        let duck = AmbientDuckControl(setPrivate: { value in host.withLock { $0.append(value) } })
        #expect(duck.report(true, write: lines.write))
        #expect(duck.report(false, write: lines.write))
        #expect(!duck.active && host.withLock { $0 } == [true, false])
        #expect(duck.observe(started: Data(started.utf8), write: lines.write) == .kept)
        #expect(!duck.active && lines.all.isEmpty)
    }
}
#endif
