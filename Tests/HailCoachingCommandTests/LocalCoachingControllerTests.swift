import HailCore
import Testing
@testable import HailCoaching

@MainActor
private final class WindowCommandFake: LocalCoachingControlling {
    var status = ForegroundCoachingStatus.off
    var controls: [String] = []
    var failStart = false
    var startupFailure: ForegroundCoaching.StartupStage?
    var retirementReason: ForegroundCoaching.RetirementReason?
    var offCalls = 0
    var joins: [CheckedContinuation<Void, Never>] = []
    var suspendJoin = false
    func control(_ line: String) throws -> Bool {
        controls.append(line)
        if failStart { throw CoachingCommandError.invalidControl }
        if line == "enable aware" { status = .active }
        return true
    }
    func off() { offCalls += 1; status = suspendJoin ? .retiring : .off }
    func join() async {
        off()
        if suspendJoin { await withCheckedContinuation { joins.append($0) } }
    }
    func releaseJoin(_ index: Int) { status = .off; joins[index].resume() }
}

@Suite("Window coaching ownership", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LocalCoachingControllerTests {
    @Test func unexpectedEndKeepsTheOwnersSafeReason() async throws {
        let fake = WindowCommandFake()
        let controller = LocalCoachingController(makeCommand: { _ in fake })
        try controller.start(arguments: [], participantAwareness: true)
        fake.retirementReason = .providerEnded
        fake.status = .off
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.state != .off, ContinuousClock.now < deadline { await Task.yield() }
        #expect(controller.state == .off && controller.lastFailure == .ended(.providerEnded))
        #expect(controller.lastFailure?.message.hasPrefix("Local transcription stopped") == true)
        await controller.stop()
        #expect(controller.lastFailure == .ended(.providerEnded))
    }
}

extension LocalCoachingControllerTests {
    @Test func safeStageSurvivesRetirementAndClearsOnFreshStart() async throws {
        let fake = WindowCommandFake()
        fake.failStart = true
        fake.startupFailure = .deviceSetup
        let controller = LocalCoachingController(makeCommand: { _ in fake })
        #expect(throws: CoachingCommandError.self) { try controller.start(arguments: [], participantAwareness: true) }
        #expect(controller.lastFailure == .start(.deviceSetup))
        await controller.stop()
        #expect(controller.state == .off && controller.lastFailure == .start(.deviceSetup))
        fake.failStart = false
        fake.startupFailure = nil
        try controller.start(arguments: [], participantAwareness: true)
        #expect(controller.lastFailure == nil)
        await controller.stop()
        #expect(controller.lastFailure == nil)
    }

    @Test func privateSetupErrorIsNeverIncludedInFailureMessage() async {
        struct PrivateError: Error, CustomStringConvertible {
            var description: String { "PRIVATE_PROFILE_ENDPOINT_CREDENTIAL" }
        }
        let controller = LocalCoachingController(makeCommand: { _ in throw PrivateError() })
        #expect(throws: CoachingCommandError.self) { try controller.start(arguments: [], participantAwareness: true) }
        #expect(controller.lastFailure == .setup)
        #expect(controller.lastFailure?.message.contains("PRIVATE") == false)
        await controller.stop()
        #expect(controller.state == .off && controller.lastFailure == .setup)
    }

    @Test func constructionAndMissingAwarenessAreInert() throws {
        var constructions = 0
        let fake = WindowCommandFake()
        let controller = LocalCoachingController(makeCommand: { _ in constructions += 1; return fake })
        #expect(controller.state == .off)
        #expect(throws: CoachingCommandError.self) { try controller.start(arguments: [], participantAwareness: false) }
        #expect(constructions == 0)
        #expect(fake.controls.isEmpty)
    }

    @Test func controlsReachSameOwnerAndStopJoinsBeforeRestart() async throws {
        let fake = WindowCommandFake()
        let controller = LocalCoachingController(makeCommand: { _ in fake })
        try controller.start(arguments: [], participantAwareness: true)
        try controller.setOwnerListening(true)
        try controller.setOwnerListening(false)
        #expect(fake.controls == ["enable aware", "owner idle", "owner answering"])
        #expect(throws: CoachingCommandError.self) { try controller.start(arguments: [], participantAwareness: true) }
        await controller.stop()
        #expect(controller.state == .off)
        #expect(fake.offCalls > 0)
        try controller.start(arguments: [], participantAwareness: true)
        await controller.stop()
    }

    @Test func failedStartupRetainsCleanupUntilExplicitStop() async throws {
        let fake = WindowCommandFake()
        fake.failStart = true
        let controller = LocalCoachingController(makeCommand: { _ in fake })
        #expect(throws: CoachingCommandError.self) { try controller.start(arguments: [], participantAwareness: true) }
        #expect(controller.state == .refused)
        #expect(fake.offCalls == 1)
        #expect(throws: CoachingCommandError.self) { try controller.start(arguments: [], participantAwareness: true) }
        await controller.stop()
        fake.failStart = false
        try controller.start(arguments: [], participantAwareness: true)
        await controller.stop()
    }

    @Test func quitRevokesBeforeReturningAndJoinsBeforeCompletion() async throws {
        let fake = WindowCommandFake()
        fake.suspendJoin = true
        let controller = LocalCoachingController(makeCommand: { _ in fake })
        try controller.start(arguments: [], participantAwareness: true)
        let retirement = controller.shutdown()
        #expect(fake.offCalls == 1)
        #expect(controller.state == .stopping)
        #expect(throws: CoachingCommandError.self) { try controller.start(arguments: [], participantAwareness: true) }
        var completed = false
        let completion = Task { await retirement.value; completed = true }
        let deadline = ContinuousClock.now + .seconds(5)
        while fake.joins.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        guard !fake.joins.isEmpty else {
            fake.suspendJoin = false
            await completion.value
            Issue.record("Quit did not reach owned retirement")
            return
        }
        _ = controller.shutdown() // Repeated Quit shares the pending retirement.
        #expect(fake.joins.count == 1)
        #expect(!completed)
        fake.releaseJoin(0)
        await completion.value
        #expect(completed && controller.state == .off)
        #expect(throws: CoachingCommandError.self) { try controller.start(arguments: [], participantAwareness: true) }
    }

    @Test func quittingAnInertOwnerNeverConstructsACommand() async {
        var constructions = 0
        let controller = LocalCoachingController(makeCommand: { _ in constructions += 1; return WindowCommandFake() })
        await controller.shutdown().value
        #expect(constructions == 0 && controller.state == .off)
        #expect(throws: CoachingCommandError.self) { try controller.start(arguments: [], participantAwareness: true) }
    }

    @Test func queuedOldStopCannotStopTheNextSession() async throws {
        let first = WindowCommandFake(), second = WindowCommandFake()
        var constructions = 0
        let controller = LocalCoachingController(makeCommand: { _ in
            constructions += 1
            return constructions == 1 ? first : second
        })
        try controller.start(arguments: [], participantAwareness: true)
        let oldRevision = controller.revision
        await controller.stop(expectedRevision: oldRevision)
        try controller.start(arguments: [], participantAwareness: true)
        await controller.stop(expectedRevision: oldRevision)
        #expect(controller.state == .active)
        #expect(second.offCalls == 0)
        await controller.stop()
    }

    @Test func olderConcurrentStopCannotClearReplacementOwner() async throws {
        let first = WindowCommandFake(), second = WindowCommandFake()
        first.suspendJoin = true
        var constructions = 0
        let controller = LocalCoachingController(makeCommand: { _ in
            constructions += 1
            return constructions == 1 ? first : second
        })
        try controller.start(arguments: [], participantAwareness: true)
        let early = Task { await controller.stop() }
        while first.joins.isEmpty { await Task.yield() }
        #expect(controller.state == .stopping)
        #expect(throws: CoachingCommandError.self) { try controller.start(arguments: [], participantAwareness: true) }
        let late = Task { await controller.stop() }
        while first.joins.count < 2 { await Task.yield() }
        first.releaseJoin(0)
        await early.value
        try controller.start(arguments: [], participantAwareness: true)
        first.releaseJoin(1)
        await late.value
        #expect(controller.state == .active)
        try controller.setOwnerListening(true)
        #expect(second.controls == ["enable aware", "owner idle"])
        #expect(second.offCalls == 0)
        await controller.stop()
    }
}
