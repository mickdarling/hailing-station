import Foundation
import Testing
@testable import HailCore

@Suite struct ReplySegmentAdmissionScopeTests {
    @Test func oneAdmissionSatisfiesOnlyTheOldestOnsetInTheSameScope() throws {
        let fixture = OnsetFixture()
        try onset(fixture)
        try onset(fixture)
        fixture.gate.ambientRequestAdmitted(in: fixture.scope)
        fixture.clock.advance(by: .milliseconds(4_100)) // A's deadline, B still pending.
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 0)
        fixture.clock.advance(by: .milliseconds(900)) // B's deadline.
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
        fixture.clock.advance(by: .seconds(5))
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
    }

    @Test func admissionInAnotherScopeSatisfiesOnlyThatScopesOnset() throws {
        let fixture = OnsetFixture()
        try onset(fixture) // A in the original endpoint/connection scope.
        fixture.scope = ReplySegmentAdmissionScope()
        try onset(fixture) // B in another endpoint/connection scope.
        fixture.gate.ambientRequestAdmitted(in: fixture.scope)
        fixture.clock.advance(by: .milliseconds(4_100))
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
        fixture.clock.advance(by: .seconds(5))
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
    }

    @Test func unmatchedAdmissionDoesNotSatisfyExistingOrFutureOnsets() throws {
        let fixture = OnsetFixture()
        fixture.gate.ambientRequestAdmitted(in: fixture.scope) // No pending entry.
        try onset(fixture)
        fixture.gate.ambientRequestAdmitted(in: ReplySegmentAdmissionScope()) // No matching scope.
        fixture.clock.advance(by: .seconds(5))
        #expect(fixture.gate.diagnostics.onsets == 1)
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
    }

    @Test func overflowCountsAndDropsOnlyTheOldestPendingEntry() throws {
        let fixture = OnsetFixture(tail: .zero)
        fixture.settings = ReplySegmentSettings(sustainedOnset: 0.05)
        let oldest = fixture.scope
        for index in 0...ReplySegmentOnsetGate.maximumPendingAdmissions {
            if index > 0 { fixture.scope = ReplySegmentAdmissionScope() }
            fixture.open()
            #expect(try !fixture.feed(-50, seconds: 0.2))
            #expect(try fixture.feed(-35, seconds: 0.05))
            fixture.gate.closeWindow()
        }
        #expect(fixture.gate.diagnostics.onsets == 17)
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
        fixture.gate.ambientRequestAdmitted(in: oldest) // Evicted token is no longer pending.
        fixture.clock.advance(by: .seconds(1)) // Evicted A's deadline cannot count it twice.
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 1)
        fixture.clock.advance(by: .milliseconds(250)) // Oldest retained entry expires.
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 2)
        fixture.gate.ambientRequestAdmitted(in: fixture.scope) // Newest entry was retained.
        fixture.clock.advance(by: .seconds(20))
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 16)
    }

    @Test func scopeChangeRequiresFreshCalibrationEvenWithTheSameWindow() throws {
        let fixture = OnsetFixture()
        try fixture.calibrate()
        #expect(try !fixture.feed(-35, seconds: 0.2))
        fixture.scope = ReplySegmentAdmissionScope()
        #expect(try !fixture.feed(-50, seconds: 0.2))
        #expect(fixture.gate.diagnostics.floors.counts.reduce(0, +) == 2)
        #expect(try fixture.feed(-35, seconds: 0.3))
        fixture.gate.ambientRequestAdmitted(in: fixture.scope)
        fixture.clock.advance(by: .seconds(5))
        #expect(fixture.gate.diagnostics.withoutAdmittedRequest == 0)
    }

    @Test func scopeAndDiagnosticsAreContentFree() {
        let scope = ReplySegmentAdmissionScope()
        #expect(scope == scope)
        #expect(scope != ReplySegmentAdmissionScope())
        let fields = Array(Mirror(reflecting: scope).children)
        #expect(fields.count == 1)
        #expect(fields.allSatisfy { $0.value is UUID })
        let diagnostics = ReplyOnsetDiagnostics()
        #expect(Set(Mirror(reflecting: diagnostics).children.compactMap(\.label)) ==
                ["onsets", "withoutAdmittedRequest", "levels", "floors"])
        #expect(Mirror(reflecting: diagnostics).children.allSatisfy {
            $0.value is UInt64 || $0.value is ReplyOnsetHistogram
        })
    }

    private func onset(_ fixture: OnsetFixture) throws {
        fixture.open()
        try fixture.calibrate()
        #expect(try fixture.feed(-35, seconds: 0.3))
        fixture.gate.closeWindow()
    }
}
