#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Privacy mode drops the agent's replies (#735 S-2c, internally duck): from entry until the confirmed exit, replies
/// to the private connection are refused (`privacyHeld`) and never reach the device; a reply streaming at entry and
/// every pending reply record are dropped for good; the host's own confirmation clips still play; after the exit,
/// new replies flow again. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyReplyTests {
    /// A fake that takes control lines and forms one ordinary synthetic request, advertising `duck` v3.
    static let quiet = FakeRightyo.ackingControl() + "\n"
        + AmbientPrivacyEntryTests.fixture(saying: "Rightyo, archive the project.", advertises: true)

    /// A request-less reply frame (`haild reply --say`), text or one audio frame of `stream`.
    static func reply(_ descriptor: ReplyDescriptor, text: String? = nil, sequence: Int = 0,
                      final: Bool = false) -> Frame {
        let payload: FramePayload = if let text {
            .text(TextPayload(text: text, isFinal: true, reply: descriptor))
        } else {
            .audio(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
                                streamID: descriptor.audioStreamID, isFinal: final,
                                bytes: Data(repeating: 0, count: 480), reply: descriptor))
        }
        return Frame(version: 1, timestamp: 1_700_000_000_000, target: RecipientTestRig.target, source: "mac-test",
                     payload: payload)
    }

    static func descriptor(audio: Bool = false) -> ReplyDescriptor {
        referenceDescriptor(nil, target: RecipientTestRig.target, audio: audio)
    }

    /// Publishes `frame` and returns the refusal, or nil when it was delivered.
    static func refusal(_ frame: Frame, on rig: DuckRig) async -> LocalReplyRefusal? {
        do {
            _ = try await rig.env.listener.publish(frame)
            return nil
        } catch let refusal as LocalReplyRefusal {
            return refusal
        } catch {
            return .internalFailure
        }
    }

    /// The exit releases the hold on the router's notice queue, after the entry's drop; replies flow once it has.
    static func flowsAgain(on rig: DuckRig, connection: UUID) async -> Bool {
        await eventually { await !rig.env.listener.replyHold.holds(connection) }
    }

    /// A correlated reply naming `request` (the request id the adapter was handed for typed input).
    static func answer(_ request: UUID, _ text: String = "synthetic answer") -> Frame {
        Frame(version: 1, timestamp: 1_700_000_000_000, target: RecipientTestRig.target, source: "mac-test",
              payload: .text(TextPayload(text: text, isFinal: true,
                                         reply: referenceDescriptor(request, target: RecipientTestRig.target))))
    }

    /// Typed input from the device (not ambient): the host dispatches it and owns its reply record. Returns its id.
    /// Found by its own frame (its utterance), not by a count and `.last`: the `quiet` fake's ambient request may land
    /// at any time, making the count jump by two or `.last` the ambient request's id (#735 timing flake).
    static func typedRequest(on rig: DuckRig) async throws -> UUID {
        let frame = sessionFrame(target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input")))
        try await recipientSocketSend(frame, on: rig.socket)
        #expect(await eventually { await rig.env.rig.adapter.contexts.contains { $0.utteranceID == frame.id } })
        let id = try #require(await rig.env.rig.adapter.contexts.first { $0.utteranceID == frame.id }).id
        // Its reply record must be pending before privacy is entered next, so the entry's drop counts it.
        #expect(await eventually {
            for peer in await rig.env.listener.peers.values where await peer.session.replyRequests[id] != nil {
                return true
            }
            return false
        })
        return id
    }

    @Test func aReplySentAfterEntryIsRefusedAndNeverReachesTheDevice() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        #expect(await Self.refusal(Self.reply(Self.descriptor(), text: "synthetic answer"), on: rig) == .privacyHeld)
        #expect(await Self.refusal(Self.reply(Self.descriptor(audio: true)), on: rig) == .privacyHeld)
        // The next frame the device sees is the pong: nothing of either reply was sent.
        try await barrier(on: rig.socket, step: "nothing forwarded")
        #expect(LocalReplyRefusal.privacyHeld.message.hasPrefix("reply refused [privacyHeld]"))
        await rig.finish()
    }

    /// A reply streaming at entry has its later (pacer-queued) frames refused, and stays dropped after the exit; a
    /// new reply after the exit flows again.
    @Test func aReplyStreamingAtEntryIsDroppedAndRepliesFlowAfterTheExit() async throws {
        let rig = try await DuckRig(script: Self.quiet)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection()), router = rig.env.router
        let streaming = Self.descriptor(audio: true)
        #expect(await Self.refusal(Self.reply(streaming, sequence: 0), on: rig) == nil)
        _ = try await receiveFrame(on: rig.socket, step: "first audio frame")
        #expect(await eventually { router.setDuck(true, connection: connection, reason: "voice") == 1 })
        #expect(await Self.refusal(Self.reply(streaming, sequence: 1), on: rig) == .privacyHeld)
        #expect(await Self.refusal(Self.reply(Self.descriptor(), text: "later"), on: rig) == .privacyHeld)
        #expect(router.setDuck(false, connection: connection, reason: "voice") == 1)
        #expect(await Self.refusal(Self.reply(streaming, sequence: 2, final: true), on: rig) == .replyStopped)
        try await barrier(on: rig.socket, step: "nothing forwarded while private")
        #expect(await Self.flowsAgain(on: rig, connection: connection))
        #expect(await Self.refusal(Self.reply(Self.descriptor(), text: "after the exit"), on: rig) == nil)
        let frame = try await receiveFrame(on: rig.socket, step: "reply after the exit")
        guard case .text(let text) = frame.payload else { Issue.record("expected text"); return }
        #expect(text.text == "after the exit")
        #expect(await eventually { rig.details("ambient_privacy_replies").first?.hasPrefix("dropped=") == true })
        await rig.finish()
    }

    /// The host's own clips are not the agent's replies: privacy on still plays while replies are held.
    @Test func confirmationClipsStillPlay() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true,
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Privacy on. I'm only listening for my name.")
        _ = try await receiveFrame(on: rig.socket, step: "privacy on clip audio")
        #expect(await eventually { rig.details("ambient_duck_confirmed").first?.hasSuffix(":sent") == true })
        #expect(await Self.refusal(Self.reply(Self.descriptor(), text: "synthetic answer"), on: rig) == .privacyHeld)
        let connection = try #require(rig.connection())
        #expect(rig.env.router.setDuck(false, connection: connection, reason: "voice") == 1)
        #expect(await Self.flowsAgain(on: rig, connection: connection))
        #expect(await Self.refusal(Self.reply(Self.descriptor(), text: "synthetic answer"), on: rig) == nil)
        await rig.finish()
    }

    /// Every reply record the session holds is dropped at entry: an answer to a request made before it finds no
    /// recipient, during privacy or after.
    @Test func pendingReplyRecordsAreDropped() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        let reference = UUID()
        #expect(try await LegacyReferenceRig.dispatch(session, reference: reference) == reference)
        let reply = TextPayload(text: "synthetic", isFinal: true, reply: referenceDescriptor(reference))
        let answer = Frame(version: 1, timestamp: 1_700_000_000_000, target: LegacyReferenceRig.target,
                           source: "mac-test", payload: .text(reply))
        #expect(await session.replyPublicationStatus(answer) == .ready)
        #expect(await session.dropRepliesForPrivacy() == 1)
        #expect(await session.replyPublicationStatus(answer) == .absent)
    }

    @Test func theHoldIsPerConnection() {
        let hold = PrivateReplyHold(), (one, two) = (UUID(), UUID())
        hold.set(true, connection: one)
        #expect(hold.holds(one) && !hold.holds(two))
        hold.set(false, connection: one)
        #expect(!hold.holds(one))
    }
}
#endif
