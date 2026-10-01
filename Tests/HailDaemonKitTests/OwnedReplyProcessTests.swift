#if os(macOS)
import Darwin
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

// Real CLI and synthetic lifecycle boundaries share the controlled cleanup harness.
// swiftlint:disable:next type_body_length
@Suite(.serialized) struct OwnedReplyProcessTests {
    @Test func normalAndNonzeroGroupsCleanOnlyAfterPinnedExit() async throws {
        for mode in ["normal", "nonzero"] {
            let fixture = try PublisherFixture(mode: mode)
            let observed = Mutex<[Int32]>([])
            var hooks = OwnedReplyGroupHooks()
            hooks.observation = { result, error in observed.withLock { $0.append(result == -1 ? error : 0) } }
            let publisher = try fixture.publisher(hooks: hooks)
            do {
                try await publisher.publish(fixture.reply())
                #expect(mode == "normal")
            } catch {
                #expect(error as? OwnedReplyPublisherError == .commandFailed && mode == "nonzero",
                        "fixed observation error codes: \(observed.withLock { $0 })")
            }
            #expect(try String(contentsOf: fixture.record, encoding: .utf8) == "owned-group-private-root")
            try await fixture.shutdown(publisher)
        }
    }

    @Test func cancellationBeforeSpawnAndBeforeResumeDoesNotExecuteWork() async throws {
        for beforeSpawn in [true, false] {
            let fixture = try PublisherFixture()
            let checkpoint = PublisherCheckpoint()
            var hooks = OwnedReplyGroupHooks()
            if beforeSpawn { hooks.beforeSpawn = { checkpoint.pause() } } else {
                hooks.beforeResume = { checkpoint.pause() }
            }
            let publisher = try fixture.publisher(hooks: hooks)
            let task = Task { try await publisher.publish(fixture.reply()) }
            do {
                try await PublisherFixture.until { checkpoint.reached }
                task.cancel()
                await #expect(throws: OwnedReplyPublisherError.cancelled) { try await task.value }
                checkpoint.resume()
                try await PublisherFixture.until { publisher.diagnostics().retained == 0 }
                #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
                try await fixture.shutdown(publisher)
            } catch {
                checkpoint.resume(); task.cancel(); _ = await task.result
                try await fixture.shutdown(publisher); throw error
            }
        }
    }

    @Test func deadlineEscalatesTERMignoringGroupAndExitedLeadersDescendant() async throws {
        for mode in ["ignore", "descendant"] {
            let fixture = try PublisherFixture(mode: mode)
            let signals = Mutex<[Int32]>([])
            var hooks = OwnedReplyGroupHooks()
            hooks.signal = { signal in signals.withLock { $0.append(signal) } }
            let publisher = try fixture.publisher(deadline: .milliseconds(400), hooks: hooks)
            await #expect(throws: OwnedReplyPublisherError.deadline) { try await publisher.publish(fixture.reply()) }
            #expect(FileManager.default.fileExists(atPath: fixture.record.path))
            try await fixture.shutdown(publisher)
            let observed = signals.withLock { $0 }
            #expect(observed.filter { $0 == SIGTERM }.count == 1)
            #expect(observed.filter { $0 == SIGKILL }.count == 1)
        }
    }

    @Test func unknownInventoryRetainsAdmissionAndFourResourceSlots() async throws {
        let fixture = try PublisherFixture()
        let unknown = Mutex(true)
        var hooks = OwnedReplyGroupHooks()
        hooks.inventory = { leader in unknown.withLock { $0 } ? nil : OwnedReplyGroupJob.inventory(leader) }
        let escalated = Mutex(0)
        hooks.escalation = { escalated.withLock { $0 += 1 } }
        let publisher = try fixture.publisher(deadline: .milliseconds(500), hooks: hooks)
        var tasks = (1...4).map { index in Task { try await publisher.publish(fixture.reply(index)) } }
        do {
            try await PublisherFixture.until { publisher.diagnostics().failed == 4 && escalated.withLock { $0 } == 4 }
            tasks += (5...16).map { index in Task { try await publisher.publish(fixture.reply(index)) } }
            try await PublisherFixture.until {
                let status = publisher.diagnostics()
                return status.retained == 4 && status.queued == 12 && status.failed == 4
            }
            await #expect(throws: OwnedReplyPublisherError.capacityExceeded) {
                try await publisher.publish(fixture.reply(17))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count == 4)
            for task in tasks { task.cancel() }
            for task in tasks { _ = await task.result }
            #expect(publisher.diagnostics().retained == 4)
            unknown.withLock { $0 = false }
            try await fixture.shutdown(publisher)
        } catch {
            unknown.withLock { $0 = false }; for task in tasks { task.cancel() }
            for task in tasks { _ = await task.result }
            try await fixture.shutdown(publisher); throw error
        }
    }

    @Test func permanentCutoffRejectsLostOrReapedIdentityWithoutRawPGIDAuthority() {
        var identity = ReplyGroupIdentity(leader: 42)
        #expect(!identity.permitsSignal(members: nil))
        #expect(!identity.permitsSignal(members: [43]))
        #expect(!identity.permitsSignal(members: [42, 0]))
        #expect(!identity.permitsSignal(members: [42, 42]))
        #expect(!identity.permitsSignal(members: Array(repeating: 42, count: 1_024)))
        var information = siginfo_t()
        identity.observe(result: -1, information: information, error: EINTR)
        #expect(identity.gateOpen)
        identity.observe(result: -1, information: information, error: ECHILD)
        #expect(identity.lost && !identity.permitsSignal(members: [42]))
        let lostReap = identity.closeForReaping(members: [42])
        #expect(!lostReap)
        var pinned = ReplyGroupIdentity(leader: 42)
        information.si_pid = 42; information.si_code = CLD_STOPPED; information.si_status = SIGSTOP
        pinned.observe(result: 0, information: information, error: 0)
        #expect(!pinned.exited && pinned.gateOpen)
        information.si_pid = 42; information.si_code = CLD_EXITED; information.si_status = 0
        pinned.observe(result: 0, information: information, error: 0)
        let earlyReap = pinned.closeForReaping(members: [42, 43])
        #expect(!earlyReap)
        let exactReap = pinned.closeForReaping(members: [42])
        #expect(exactReap)
        #expect(!pinned.permitsSignal(members: [42]))
        let lateReap = pinned.closeForReaping(members: [42])
        #expect(!lateReap)
        var wrongObservation = ReplyGroupIdentity(leader: 42)
        information.si_pid = 43
        wrongObservation.observe(result: 0, information: information, error: 0)
        #expect(wrongObservation.lost && !wrongObservation.gateOpen)
    }

    @Test func trustedActualCLIProducesThreeCorrelatedFramesAndInheritedRendererGroup() async throws {
        let fixture = try PublisherFixture(cli: true)
        let recorder = PublisherEndpointRecorder()
        let endpoint = try LocalReplyEndpoint(socketURL: fixture.base.appendingPathComponent("reply.sock"),
                                             destination: recorder,
                                             audit: AuditLog(directory: fixture.base.appendingPathComponent("audit")))
        try await endpoint.start()
        let publisher = try fixture.publisher()
        let reply = fixture.reply()
        do {
            try await publisher.publish(reply)
            let frames = await recorder.frames
            #expect(frames.count == 3)
            #expect(frames.allSatisfy { $0.publisherTestDescriptor?.requestID == reply.requestID })
            #expect(Set(frames.compactMap { $0.publisherTestDescriptor?.id }).count == 1)
            #expect(try String(contentsOf: fixture.record, encoding: .utf8) == "owned-cli-group-private-root")
            await endpoint.stop()
            try await fixture.shutdown(publisher)
        } catch {
            let frames = await recorder.frames.count
            let stage = (try? String(contentsOf: fixture.record, encoding: .utf8)) ?? "not-started"
            #expect(Bool(false), "synthetic CLI fixture phase: \(stage); frames: \(frames)")
            await endpoint.stop(); try await fixture.shutdown(publisher); throw error
        }
    }

    @Test func actualCLISocketWaitCancellationAndDeadlineDoNotWaitForTransaction() async throws {
        for cancellation in [true, false] {
            let fixture = try PublisherFixture(cli: true)
            let recorder = PublisherEndpointRecorder(blockAt: 1)
            let endpoint = try LocalReplyEndpoint(socketURL: fixture.base.appendingPathComponent("reply.sock"),
                                                 destination: recorder,
                                                 audit: AuditLog(
                                                    directory: fixture.base.appendingPathComponent("audit")))
            try await endpoint.start()
            let publisher = try fixture.publisher(deadline: .milliseconds(400))
            let task = Task { try await publisher.publish(fixture.reply()) }
            do {
                try await PublisherFixture.until { await recorder.frames.count == 1 }
                if cancellation { task.cancel() }
                let expected: OwnedReplyPublisherError = cancellation ? .cancelled : .deadline
                await #expect(throws: expected) { try await task.value }
                #expect(await recorder.frames.count == 1)
                await recorder.release(); await endpoint.stop()
                try await fixture.shutdown(publisher)
            } catch {
                task.cancel(); _ = await task.result
                await recorder.release(); await endpoint.stop()
                try await fixture.shutdown(publisher); throw error
            }
        }
    }
}

private extension Frame {
    var publisherTestDescriptor: ReplyDescriptor? {
        switch payload {
        case .text(let value): value.reply
        case .audio(let value): value.reply
        default: nil
        }
    }
}
#endif
