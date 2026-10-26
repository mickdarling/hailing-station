import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(2))) struct RecipientPublicationGateTests {
    @Test func barrierTimeoutIsRecoverableAndSticky() async {
        let gate = RecipientPublicationGate(timeout: .milliseconds(0))
        await #expect(throws: RecipientPublicationTestError.admissionTimedOut) {
            try await gate.waitEntered()
        }
        #expect(gate.timedOut)
        gate.release()
        gate.release()
        #expect(!gate.block(onDedicatedQueue: false))
        #expect(gate.timedOut)
    }

    @Test func publicationTimeoutFailsClosedAndRecordsOneInconclusiveIssue() async throws {
        let clock = RecipientPublicationClock(timeout: .milliseconds(0))
        let rig = try await RecipientTestRig.make()
        let session = HostSession(
            host: rig.host, authorizer: PersonalTerminalAuthorizer(), requestClock: clock.now
        )
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let frame = recipientText(recipientDescriptor(try await rig.submit(on: session)))
        let submitted = Mutex(0)
        clock.arm()
        let publication = Task(executorPreference: clock.executor) {
            await session.enqueueHostReply(frame) { submitted.withLock { $0 += 1 }; return true }
        }
        // No revocation and no release: admission must refuse solely because the harness timed out.
        #expect(!(await publication.value))
        #expect(clock.gate.timedOut)
        #expect(clock.gate.usedDedicatedQueue)
        let issues = Mutex(0)
        await withKnownIssue("Deliberately injected #846 timeout") {
            #expect(await clock.finish(publication) == .inconclusive)
        } matching: { issue in
            guard case .unconditional = issue.kind,
                  issue.comments.contains(where: { $0.rawValue.contains("#846: harness gate timed out") }) else {
                return false
            }
            issues.withLock { $0 += 1 }
            return true
        }
        #expect(issues.withLock { $0 } == 1)
        #expect(!(await session.enqueueHostReply(frame) { submitted.withLock { $0 += 1 }; return true }))
        #expect(submitted.withLock { $0 } == 0)
    }
}
