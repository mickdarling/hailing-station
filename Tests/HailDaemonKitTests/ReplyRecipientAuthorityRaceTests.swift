import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(2))) struct ReplyRecipientAuthorityRaceTests {
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
        var revoked = true
        do {
            try await clock.gate.waitEntered()
            if lockdown {
                _ = await rig.host.engageLockdown(reason: "synthetic publication race")
            } else {
                revoked = try await rig.host.deny(RecipientTestRig.target)
            }
        } catch {
            guard await clock.finish(publication) != nil else { return }
            throw error
        }
        guard let accepted = await clock.finish(publication) else { return }
        #expect(clock.gate.usedDedicatedQueue)
        #expect(revoked)
        #expect(!accepted)
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
            await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "replacement-binding")])
        } catch {
            guard await clock.finish(publication) != nil else { return }
            throw error
        }
        guard let accepted = await clock.finish(publication) else { return }
        #expect(clock.gate.usedDedicatedQueue)
        #expect(!accepted)
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
