import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite struct CodexRecoveryAuthorityTests {
    @Test func refusalAtFullCapacityNeedsNoPositiveAuthoritySlot() throws {
        let fixture = RightyoRequestOutcomeTests(), ledger = AmbientRequestOutcomes(session: "tool-demo")
        ledger.observe(try fixture.started())
        let generation = try #require(ledger.generation)
        for index in 0..<64 {
            #expect(ledger.register(host: UUID(), producer: "tool-demo:r\(index)", generation: generation))
        }
        #expect(!ledger.register(host: UUID(), producer: "tool-demo:extra", generation: generation))
        var outcome: RightyoRequestOutcome?
        #expect(ledger.refuse(producer: "tool-demo:extra", generation: generation,
            write: { outcome = $0; return true }))
        #expect(outcome?.state == .failed && outcome?.request == "tool-demo:extra")
        ledger.close()
        #expect(!ledger.refuse(producer: "tool-demo:extra", generation: generation, write: { _ in true }))
    }
    @Test func revocationClosesRegisteredWorkerInputsBeforeReturning() throws {
        let fixture = RightyoRequestOutcomeTests(), ledger = AmbientRequestOutcomes(session: "tool-demo")
        ledger.observe(try fixture.started())
        let generation = try #require(ledger.generation), closed = Mutex(false)
        let key = ledger.watch(producer: "tool-demo:request", generation: generation, stop: {
            closed.withLock { $0 = true }
        })
        _ = try #require(key)
        ledger.close()
        #expect(closed.withLock { $0 })
        #expect(ledger.watch(producer: "tool-demo:later", generation: generation, stop: {}) == nil)
    }
    @Test func anExactRequestAuthorityGateCannotBeRenewedAfterPrivacyOrTermination() throws {
        let fixture = RightyoRequestOutcomeTests(), ledger = AmbientRequestOutcomes(session: "tool-demo"), host = UUID()
        ledger.observe(try fixture.started())
        let generation = try #require(ledger.generation)
        #expect(ledger.register(host: host, producer: "tool-demo:request", generation: generation))
        #expect(ledger.withAuthority(host: host, generation: generation, { true }) == true)
        ledger.setPrivate(true); ledger.setPrivate(false)
        #expect(ledger.withAuthority(host: host, generation: generation, { true }) == nil)
    }
}
