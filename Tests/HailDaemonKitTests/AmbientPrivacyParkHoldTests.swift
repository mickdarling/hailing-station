#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #941: a stream restored private is private exactly as a live privacy entry leaves it: the reply hold is set with the
/// host's privacy state, the device is told, privacy wins over the MM-E parks and held modes, and nothing is restored
/// onto a torn-down connection. Synthetic devices only; every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyParkHoldTests {
    static func park(_ rig: RestoreRig) -> UUID {
        let from = UUID()
        rig.router.state.withLock {
            $0.parks[from] = ParkedPrivacy(connection: from, device: nil, parkedAt: rig.clock.now())
        }
        return from
    }

    static func publish(_ frame: Frame, on rig: RestoreRig) async -> LocalReplyRefusal? {
        do {
            _ = try await rig.env.listener.publish(frame)
            return nil
        } catch let refusal as LocalReplyRefusal {
            return refusal
        } catch {
            return .internalFailure
        }
    }

    /// The agent's replies and the host clips that respect the hold (#913) are held on the restored connection, normal
    /// or resume start, as on a live entry, until the owner's off releases them.
    @Test(arguments: [false, true])
    func aRestoredStreamHoldsTheAgentsReplies(resume: Bool) async throws {
        let rig = try await AmbientPrivacyParkTests.privacyDropped()
        defer { rig.close() }
        let (socket, connection) = try await rig.start(resume: resume)
        let listener = rig.env.listener
        #expect(await listener.replyHold.holds(connection))
        let reply = AmbientPrivacyReplyTests.reply(AmbientPrivacyReplyTests.descriptor(), text: "synthetic answer")
        #expect(await Self.publish(reply, on: rig) == .privacyHeld)
        #expect(await listener.acknowledgeAmbient(connection: connection, target: RecipientTestRig.target,
                                                  clip: RestoreRig.resumed, heldWhilePrivate: true)
                == "suppressed_privacy")
        try await barrier(on: socket, step: "nothing forwarded while restored private")
        #expect(await eventually { rig.details("ambient_privacy_replies").first?.hasPrefix("dropped=") == true },
                "restore drop log marker")
        #expect(await eventually { rig.router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        #expect(rig.router.setDuck(false, connection: connection, reason: "voice") == 1)
        #expect(await eventually { await !listener.replyHold.holds(connection) }, "hold released after the off")
        let later = AmbientPrivacyReplyTests.reply(AmbientPrivacyReplyTests.descriptor(), text: "after the off")
        #expect(await Self.publish(later, on: rig) == nil)
        #expect(await listener.acknowledgeAmbient(connection: connection, target: RecipientTestRig.target,
                                                  clip: RestoreRig.resumed, heldWhilePrivate: true) == "sent")
        await rig.finish()
    }

    /// A device that takes `duck_mode` is told privacy is on, reason `device` (a protocol reason, never dropped), so its
    /// switch shows the host's state.
    @Test func theDeviceIsToldItIsPrivate() async throws {
        let rig = try await AmbientPrivacyParkTests.privacyDropped()
        defer { rig.close() }
        let (socket, _) = try await rig.start(capabilities: ["probe", DuckMode.capability])
        var told: FramePayload?
        for _ in 0..<4 where told == nil {
            let frame = try await receiveFrame(on: socket, step: "restored duck mode notice")
            if case .control(.duckMode) = frame.payload { told = frame.payload }
        }
        #expect(told == .control(.duckMode(on: true, reason: "device", expires: nil)))
        #expect(await eventually { rig.details("ambient_duck_device").last == "on=true device=sent" },
                "restored device notice log marker")
        await rig.finish()
    }

    /// Privacy wins over a parked meeting (MM-E): the restored-private start discards it and takes nothing.
    @Test func aRestoredPrivateStartDiscardsAParkedMeeting() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        _ = Self.park(rig)
        let (_, connection) = try await rig.start()
        #expect(rig.router.duckMode(connection: connection) && !rig.router.meetingMode(connection: connection))
        #expect(rig.parked == nil)
        await rig.drainMeetingChanges()
        #expect(rig.details("meeting_restored").isEmpty)
        #expect(await eventually { rig.details("ambient_park_discarded") == ["reason=privacy mode=meeting"] },
                "meeting park discarded by restored privacy marker")
        await rig.finish()
        #expect(rig.control(2)?.contains("media") != true)
    }

    /// A live connection holding media mode that starts a fresh stream while privacy is parked leaves media mode, so
    /// it is never in both, and its stream starts private.
    @Test func aConnectionHoldingMediaLeavesItWhenRestoredPrivate() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let (socket, connection) = try await rig.connect()
        rig.router.setMedia(true, connection: connection, reason: "voice")
        #expect(rig.router.mediaMode(connection: connection))
        _ = Self.park(rig)
        try await recipientSocketSend(audio(UUID(), 0), on: socket)
        let router = rig.router
        #expect(await eventually { router.activeConnection() == connection }, "media holder start marker")
        #expect(router.duckMode(connection: connection) && !router.mediaMode(connection: connection))
        #expect(await eventually { rig.details("ambient_mode_ended").first?.contains("mode=media") == true },
                "media ended by restored privacy marker")
        await rig.finish()
        #expect((try? rig.fake.recorded("argv.1.txt"))?.contains("--start-private") == true)
    }

    /// Nothing is restored onto a torn-down connection (no privacy state left behind for it), nor onto one already
    /// private (its arming is kept).
    @Test func nothingIsRestoredOntoATornDownOrPrivateConnection() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        _ = Self.park(rig)
        let (closed, held, token) = (UUID(), UUID(), UUID())
        let router = rig.router
        router.state.withLock { state in
            state.closed.insert(closed)
            state.duck[held] = AmbientDuckTimer(token: token, timer: nil)
            router.restorePrivacy(to: closed, in: &state)
            router.restorePrivacy(to: held, in: &state)
        }
        #expect(!router.duckMode(connection: closed) && router.duckArming(connection: held) == token)
        #expect(await !rig.env.listener.replyHold.holds(closed))
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_privacy_restored").isEmpty)
        await rig.finish()
    }

    /// A child is admitted while privacy is parked only onto a private connection (#941 fail closed).
    @Test func admissionWhilePrivacyIsParkedNeedsAPrivateConnection() {
        let connection = UUID()
        var state = AmbientRightyoRouter.State()
        #expect(AmbientRightyoRouter.admitsPrivacy(connection, in: state))
        let parked = UUID()
        state.parks[parked] = ParkedPrivacy(connection: parked, device: nil, parkedAt: Date())
        #expect(!AmbientRightyoRouter.admitsPrivacy(connection, in: state))
        state.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil)
        #expect(AmbientRightyoRouter.admitsPrivacy(connection, in: state))
    }
}
#endif
