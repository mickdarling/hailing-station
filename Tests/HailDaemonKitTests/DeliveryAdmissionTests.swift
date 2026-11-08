import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

private enum AdmissionTestError: Error { case retired, launch }

private final class AdmissionTestEvents: Sendable {
    private let events = Mutex<[String]>([])
    func append(_ event: String) { events.withLock { $0.append(event) } }
    var snapshot: [String] { events.withLock { $0 } }
}

private func admissionGate(_ permit: ReplyPublicationPermit) -> DeliveryAdmission.Gate {
    .init(validate: {
        guard permit.performIfCurrent({ true }) == true else { throw AdmissionTestError.retired }
    }, perform: { operation in
        guard try permit.performIfCurrent({ try operation(); return true }) == true else {
            throw AdmissionTestError.retired
        }
    })
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct DeliveryAdmissionTests {
    @Test(arguments: DeliveryAdmission.Stage.allCases)
    func operationRefusedAfterRetirement(_ stage: DeliveryAdmission.Stage) throws {
        let gate = ReplyPublicationAuthority()
        let authority = DeliveryAuthority(admission: .init(gates: [stage: admissionGate(gate.issuePermit())]))
        try authority.requireCurrent()
        gate.invalidate()
        var calls = 0
        #expect(throws: AdmissionTestError.retired) { try authority.admit { calls += 1 } }
        #expect(calls == 0)
    }

    @Test func operationRunsExactlyOnceAndReturnsItsResult() throws {
        let authority = DeliveryAuthority(admission: .init(gates: [:]))
        #expect(authority.supportsAdmission)
        var calls = 0
        let result = try authority.admit { calls += 1; return 42 }
        #expect(result == 42 && calls == 1)
        let optional: Int? = try authority.admit { nil }
        #expect(optional == nil)
    }

    @Test func thrownLaunchResultReleasesAllGates() throws {
        let owners = DeliveryAdmission.Stage.allCases.map { _ in ReplyPublicationAuthority() }
        let gates = Dictionary(uniqueKeysWithValues: zip(DeliveryAdmission.Stage.allCases, owners).map {
            ($0, admissionGate($1.issuePermit()))
        })
        let authority = DeliveryAuthority(admission: .init(gates: gates))
        var calls = 0
        #expect(throws: AdmissionTestError.launch) {
            try authority.admit { calls += 1; throw AdmissionTestError.launch }
        }
        #expect(calls == 1)
        #expect(try authority.admit { true })
        for owner in owners { owner.invalidate() }
        #expect(throws: AdmissionTestError.retired) { try authority.admit { calls += 1 } }
        #expect(calls == 1)
    }

    @Test func fixedGateOrderSurroundsOperationAndSkipsAbsentStages() throws {
        let events = AdmissionTestEvents()
        let expected = ["targetPolicy", "taskOutputFence", "replyPermit", "bindingLease", "sessionUpdateFence",
                        "ambientRouter", "privacyHold", "peerLifecycle", "attemptCancellation"]
        let gates = Dictionary(uniqueKeysWithValues: DeliveryAdmission.Stage.allCases.reversed().map { stage in
            (stage, DeliveryAdmission.Gate(validate: { events.append("validate \(stage)") }, perform: { operation in
                events.append("enter \(stage)")
                defer { events.append("exit \(stage)") }
                try operation()
            }))
        })
        let authority = DeliveryAuthority(admission: .init(gates: gates))
        try authority.requireCurrent()
        #expect(events.snapshot == expected.map { "validate \($0)" })
        try authority.admit { events.append("launch") }
        // Built in typed steps: host Swift 6.2.4 cannot type-check the single concatenation in reasonable time.
        let validated: [String] = expected.map { "validate \($0)" }
        let entered: [String] = expected.map { "enter \($0)" }
        let exited: [String] = expected.reversed().map { "exit \($0)" }
        let admittedOrder: [String] = validated + entered + ["launch"] + exited
        #expect(events.snapshot == admittedOrder)
        let sparseGates: [DeliveryAdmission.Stage: DeliveryAdmission.Gate?] = [
            .peerLifecycle: gates[.peerLifecycle], .targetPolicy: gates[.targetPolicy]
        ]
        let sparse = DeliveryAuthority(admission: .init(gates: sparseGates.compactMapValues { $0 }))
        try sparse.admit { events.append("sparse launch") }
        #expect(Array(events.snapshot.suffix(5)) == ["enter targetPolicy", "enter peerLifecycle", "sparse launch",
                                                    "exit peerLifecycle", "exit targetPolicy"])
    }

    @Test func validationCommitsNeitherCancellationNorAttempts() throws {
        let committed = Mutex(false)
        let decisions = DeliveryAdmission.Gate(validate: {}, perform: { operation in
            committed.withLock { $0 = true }
            try operation()
        })
        let authority = DeliveryAuthority(admission: .init(gates: [.attemptCancellation: decisions]))
        try authority.requireCurrent()
        try authority.requireCurrent()
        #expect(!committed.withLock { $0 })
        try authority.admit {}
        #expect(committed.withLock { $0 })
    }

    @Test(arguments: [false, true])
    func invalidGateCannotRepeatOperation(_ repeatOperation: Bool) {
        let gate = DeliveryAdmission.Gate(validate: {}, perform: { operation in
            if repeatOperation { try operation(); try operation() }
        })
        let authority = DeliveryAuthority(admission: .init(gates: [.targetPolicy: gate]))
        var calls = 0
        #expect(throws: DeliveryAdmissionError.invalidGate) { try authority.admit { calls += 1 } }
        #expect(calls == (repeatOperation ? 1 : 0))
    }
}

extension DeliveryAdmissionTests {
    @Test(arguments: DeliveryAdmission.Stage.allCases)
    func admissionIsOrderedAgainstRetirement(_ stage: DeliveryAdmission.Stage) async throws {
        let gate = ReplyPublicationAuthority()
        let authority = DeliveryAuthority(admission: .init(gates: [stage: admissionGate(gate.issuePermit())]))
        let blocked = PolicyWriteGate()
        defer { blocked.fire() }
        let events = AdmissionTestEvents()
        let retiring = AsyncStream<Void>.makeStream()
        let operation = Task(executorPreference: blocked.executor) {
            try authority.admit {
                events.append("operation entered")
                blocked.suspend()
                events.append("operation completed")
                return 42
            }
        }
        try await blocked.waitUntilSuspended()
        let retirement = Task(executorPreference: RecipientPublicationExecutor()) {
            events.append("retirement invoked")
            retiring.continuation.yield(())
            gate.invalidate()
            events.append("retirement completed")
        }
        var arrivals = retiring.stream.makeAsyncIterator()
        _ = await arrivals.next()
        #expect(events.snapshot == ["operation entered", "retirement invoked"])
        #expect(try await blocked.finish(operation) == 42)
        await retirement.value
        #expect(events.snapshot == ["operation entered", "retirement invoked",
                                    "operation completed", "retirement completed"])
        #expect(throws: AdmissionTestError.retired) { try authority.admit { events.append("later operation") } }
        #expect(events.snapshot.count == 4)
    }
}
