import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Bounded, deterministic barriers around synthetic admission. No devices, speech or providers are used.
private final class RecipientPublicationClock: Sendable {
    private let origin = ContinuousClock.now
    private let remaining = Mutex<Int?>(nil)
    let gate = RecipientPublicationGate()
    let executor = RecipientPublicationExecutor()
    // Pruning is followed by the pre-gate lifetime check; pause there, before either authority lock.
    func arm() { remaining.withLock { $0 = 2 } }
    func now() -> ContinuousClock.Instant {
        let block = remaining.withLock { count in
            guard let old = count else { return false }
            count = old > 1 ? old - 1 : nil
            return old == 1
        }
        if block, !gate.block(onDedicatedQueue: executor.isExecuting) {
            return origin.advanced(by: .seconds(120))
        }
        return origin
    }
}

@Suite(.serialized) struct ReplyRecipientAuthorityRaceTests {
    private struct Setup {
        let rig: RecipientTestRig
        let session: HostSession
        let frame: Frame
    }
    private func setup(_ clock: RecipientPublicationClock) async throws -> Setup {
        let rig = try await RecipientTestRig.make()
        let session = HostSession(
            host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test", requestClock: clock.now
        )
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        return Setup(rig: rig, session: session, frame: recipientText(
            recipientDescriptor(try await rig.submit(on: session))
        ))
    }

    @Test(arguments: [false, true])
    func completedRevocationBeforeEnqueueRejectsFrame(lockdown: Bool) async throws {
        let clock = RecipientPublicationClock()
        let setup = try await setup(clock)
        let rig = setup.rig
        let session = setup.session
        let frame = setup.frame
        let submitted = Mutex(0)
        clock.arm()
        let publication = Task(executorPreference: clock.executor) {
            await session.enqueueHostReply(frame) { submitted.withLock { $0 += 1 }; return true }
        }
        do {
            try await clock.gate.waitEntered()
            try #require(clock.gate.usedDedicatedQueue)
            if lockdown {
                _ = await rig.host.engageLockdown(reason: "synthetic publication race")
            } else {
                #expect(try await rig.host.deny(RecipientTestRig.target))
            }
        } catch {
            clock.gate.release()
            _ = await publication.value
            throw error
        }
        clock.gate.release()
        #expect(!(await publication.value))
        #expect(!clock.gate.timedOut)
        #expect(submitted.withLock { $0 } == 0)
    }

    @Test func completedBindingReplacementBeforeEnqueueRejectsFrame() async throws {
        let clock = RecipientPublicationClock()
        let setup = try await setup(clock)
        let rig = setup.rig
        let session = setup.session
        let frame = setup.frame
        let submitted = Mutex(0)
        clock.arm()
        let publication = Task(executorPreference: clock.executor) {
            await session.enqueueHostReply(frame) { submitted.withLock { $0 += 1 }; return true }
        }
        do {
            try await clock.gate.waitEntered()
            try #require(clock.gate.usedDedicatedQueue)
            await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "replacement-binding")])
        } catch {
            clock.gate.release()
            _ = await publication.value
            throw error
        }
        clock.gate.release()
        #expect(!(await publication.value))
        #expect(!clock.gate.timedOut)
        #expect(submitted.withLock { $0 } == 0)
    }

    @Test func barrierTimeoutIsRecoverableRatherThanAProcessTrap() async {
        let gate = RecipientPublicationGate(timeout: .milliseconds(0))
        await #expect(throws: RecipientPublicationTestError.admissionTimedOut) {
            try await gate.waitEntered()
        }
        #expect(!gate.block(onDedicatedQueue: false))
        #expect(gate.timedOut)
        gate.release()
        gate.release()
    }

    @Test func restorationWithoutAnInterveningReplyCannotReviveAdmissionTickets() async throws {
        for policy in [false, true] {
            let clock = RecipientPublicationClock()
            let setup = try await setup(clock)
            let rig = setup.rig
            let session = setup.session
            let frame = setup.frame
            if policy {
                _ = try await rig.host.deny(RecipientTestRig.target)
                _ = try await rig.host.allow(RecipientTestRig.target, tier: .open)
            } else {
                await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "replacement-binding")])
                await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "reply-binding")])
            }
            let submitted = Mutex(0)
            #expect(!(await session.enqueueHostReply(frame) { submitted.withLock { $0 += 1 }; return true }))
            #expect(submitted.withLock { $0 } == 0)
        }
    }

    @Test func revocationDuringHandoffCannotCommitRequestEvenIfRestoredBeforeCompletion() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        await rig.adapter.holdHandoff()
        let delivery = Task {
            await session.receive(sessionFrame(
                target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input"))
            ))
        }
        await rig.adapter.waitForHandoff()
        let context = try #require(await rig.adapter.contexts.last)
        _ = try await rig.host.deny(RecipientTestRig.target)
        _ = try await rig.host.allow(RecipientTestRig.target, tier: .open)
        await rig.adapter.releaseHandoff()
        #expect(!(await delivery.value).frames.isEmpty)
        #expect(!(await session.replyRequests.keys.contains(context.id)))
        #expect(!(await session.acceptsHostReply(recipientText(recipientDescriptor(context)))))
    }

    @Test func unsupportedCooperativeLeaseRefusesBeforeContextualInputSideEffect() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter)
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: rig.binding.targetID))))
        let result = await session.receive(sessionFrame(
            target: rig.binding.targetID, payload: .text(TextPayload(text: "synthetic input"))
        ))
        #expect(!result.frames.isEmpty)
        #expect(await adapter.contextual.isEmpty)
        #expect(await adapter.legacy.isEmpty)
        #expect(await session.replyRequests.isEmpty)
    }
}
