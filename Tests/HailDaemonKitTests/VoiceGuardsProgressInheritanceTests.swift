import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Real listener acceptance installs the interaction callback; only transports, targets and clocks are synthetic.
@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceGuardsProgressInheritanceTests {
    @Test(arguments: [false, true])
    func ambientInteractionCannotAuthorizeALaterProgressWake(_ timeout: Bool) async throws {
        let rig = try await VoiceGuardsProgressRig.make()
        let (listener, session, clock) = (rig.listener, rig.session, rig.clock)
        let (target, binding, connection) = ("final:reply", "synthetic-binding", await session.connectionID)
        defer { rig.pair.close() }
        let finished = AsyncStream<Bool>.makeStream()
        let failCPU = Mutex(false)
        let budget = GuardBudgetClock(now: { .now }, cpuNow: { failCPU.withLock { $0 ? nil : .zero } })
        let refusal = RightyoGuardRefusal()
        try await RightyoGuardRefusal.$current.withValue(refusal) {
            try await GuardBudgetClock.$current.withValue(budget) {
                try await TaskProgressWakeScope.$didFinishWake.withValue({
                    finished.continuation.yield(HostSession.ambientInputDispatch)
                }, operation: {
                    var deadlines = clock.scheduled.stream.makeAsyncIterator()
                    var wakes = finished.stream.makeAsyncIterator()
                    let id = UUID()
                    let start = await listener.taskProgress(.init(action: .start, target: target,
                                                                  task: id, seconds: 60))
                    try #require(start.task == id && start.nextDueInSeconds == 60)
                    _ = try #require(await deadlines.next())
                    var ambientDeadlines = rig.ambientDeadlines.stream.makeAsyncIterator()
                    let dispatcher = AmbientListenerDispatcher(listener: listener, audit: nil,
                        selection: await session.selectionGeneration, streamTarget: target)
                    _ = try await dispatcher.dispatch(.init(connection: connection, target: target, binding: binding,
                        text: "synthetic benign utterance"), routed: false)
                    // The live accept callback must reschedule under ambient context before time advances.
                    _ = try #require(await ambientDeadlines.next())
                    failCPU.withLock { $0 = timeout }
                    clock.advance(by: .seconds(60))
                    try #require(await wakes.next() == true, "the regression must exercise inherited ambient context")
                    #expect(await listener.taskProgress(.init(action: .status)).task == nil)
                    #expect(await rig.adapter.deliveries == ["synthetic benign utterance"])
                    #expect(rig.log.lines.isEmpty)
                    #expect(refusal.ruleTokens == "custom", "the wake must reach guard escalation")
                })
            }
        }
        await listener.stop()
    }
}

extension WebSocketListener {
    func voiceGuardOnlySession() async -> HostSession? {
        guard peers.count == 1, let peer = peers.values.first else { return nil }
        return await peer.session
    }
    func voiceGuardRecordInput(connection: UUID, generation: UUID) {
        lastInput.record(.init(connection: connection, generation: generation, at: .now), for: "final:reply")
    }
}

private struct VoiceGuardsProgressRig {
    let host: HailHost
    let listener: WebSocketListener
    let session: HostSession
    let clock: ProgressTestClock
    let adapter: FinalDeliveryAdapter
    let log: VoiceGuardsLog
    let pair: FallbackSocketPair
    let ambientDeadlines: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)

    static func make() async throws -> Self {
        let adapter = FinalDeliveryAdapter(), registry = Registry(), log = VoiceGuardsLog()
        try await registry.register(adapter)
        let target = "final:reply", binding = "synthetic-binding"
        let rule = GuardPattern(name: "status rule", regex: "Task progress check")
        var policy = Policy(guardPatterns: [rule], voiceGuards: .off)
        try policy.allow(target, binding: binding, tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy), voiceGuardLog: log.record)
        let wiring = TaskProgressGuardedWiring(), clock = ProgressTestClock()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "synthetic-host", ambient: wiring)
        await listener.enableSessionUpdates()
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(port: port, selecting: [target],
                                                       capabilities: [SessionUpdateCard.capability])
        let session = try #require(await listener.voiceGuardOnlySession())
        let connection = await session.connectionID
        wiring.select(connection: connection)
        let ambientDeadlines = AsyncStream<Void>.makeStream()
        await listener.enableTaskProgress(clock: .init(now: { clock.now }, sleepUntil: { due in
            if HostSession.ambientInputDispatch { ambientDeadlines.continuation.yield(()) }
            try await clock.clock.sleepUntil(due)
        }))
        // Seed enrollment eligibility without launching an interaction callback before the tested dispatch.
        await listener.voiceGuardRecordInput(connection: connection, generation: session.selectionGeneration)
        return Self(host: host, listener: listener, session: session, clock: clock,
                    adapter: adapter, log: log, pair: pair, ambientDeadlines: ambientDeadlines)
    }
}
