import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Bounded, deterministic barriers around synthetic admission. No devices, speech or providers are used.
private final class RecipientPublicationGate: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func block() {
        entered.signal()
        precondition(released.wait(timeout: .now() + 15) == .success, "synthetic publication timed out")
    }
    func waitEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [entered] in
                precondition(entered.wait(timeout: .now() + 15) == .success, "synthetic admission timed out")
                continuation.resume()
            }
        }
    }
    func release() { released.signal() }
}

private final class RecipientPublicationClock: Sendable {
    private let origin = ContinuousClock.now
    private let remaining = Mutex<Int?>(nil)
    let gate = RecipientPublicationGate()
    // Pruning is followed by the pre-gate lifetime check; pause there, before either authority lock.
    func arm() { remaining.withLock { $0 = 2 } }
    func now() -> ContinuousClock.Instant {
        let block = remaining.withLock { count in
            guard let old = count else { return false }
            count = old > 1 ? old - 1 : nil
            return old == 1
        }
        if block { gate.block() }
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
        let publication = Task {
            await session.enqueueHostReply(frame) { submitted.withLock { $0 += 1 }; return true }
        }
        await clock.gate.waitEntered()
        if lockdown {
            _ = await rig.host.engageLockdown(reason: "synthetic publication race")
        } else {
            #expect(try await rig.host.deny(RecipientTestRig.target))
        }
        clock.gate.release()
        #expect(!(await publication.value))
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
        let publication = Task {
            await session.enqueueHostReply(frame) { submitted.withLock { $0 += 1 }; return true }
        }
        await clock.gate.waitEntered()
        await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "replacement-binding")])
        clock.gate.release()
        #expect(!(await publication.value))
        #expect(submitted.withLock { $0 } == 0)
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
