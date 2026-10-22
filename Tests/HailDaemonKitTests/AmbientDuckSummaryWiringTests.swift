#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Duck mode's end through the listener (#735 H-5): the spoken exit, the auto-end and the device's end each send the
/// owner's session to the selected session once, through the listener's own dispatch; media mode sends nothing. H-2's
/// own log lines are as before, the summary's carry counts only, and the owner's "save that" goes to the `notes`
/// destination alone. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckSummaryWiringTests {
    static let saved = AmbientAckClip(pcm: Data(repeating: 7, count: 480), sampleRate: 24_000, text: "Saved.")
    static let notSaved = AmbientAckClip(pcm: Data(repeating: 8, count: 480), sampleRate: 24_000,
                                         text: "That didn't save.")
    static let clips = AmbientAckLibrary(clips: ["confirmsaved": [saved], "confirmnotsaved": [notSaved]])
    static let thought = "First synthetic thought."

    /// The owner enters, thinks once, asks the status cue (so the test knows the thought was taken), then `ending`.
    /// With `lingers`, the fake RightyO waits two seconds after the audio ends before it stops.
    static func rig(_ ending: [String], timeout: TimeInterval = 30, lingers: Bool = false) async throws -> DuckRig {
        var script = try AmbientDuckCueWiringTests.script([thought, "Are you still listening?"] + ending)
        if lingers { script = script.replacingOccurrences(of: "/bin/cat > /dev/null\n",
                                                          with: "/bin/cat > /dev/null\n/bin/sleep 2\n") }
        return try await DuckRig(script: script, clips: clips, timeout: timeout)
    }

    /// Waits for the status cue, so the thought before it is in the buffer.
    static func thoughtTaken(_ rig: DuckRig) async -> Bool {
        await eventually { rig.details("ambient_duck_cue").contains { $0.hasPrefix("cue=status") } }
    }

    static let sent = "outcome=sent turns=1 bytes=\(thought.utf8.count) confirm=none"

    @Test func theSpokenExitSendsOneSummary() async throws {
        let rig = try await Self.rig(["Rightyo, done thinking."])
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck_summary") == [Self.sent] })
        #expect(await rig.env.rig.adapter.contexts.count == 1)
        await rig.finish()
        // H-2's own lines, as before H-5.
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=voice reported=1"])
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":false}\n")
        let all = ["ambient_duck_summary", "ambient_duck", "ambient_duck_confirmed", "ambient_duck_cue"]
            .flatMap(rig.details)
        #expect(!all.contains { $0.contains("synthetic") || $0.contains("thinking") })
    }

    /// The auto-end is the spoken exit but for its reason.
    @Test func theAutoEndSendsOneSummary() async throws {
        let rig = try await Self.rig([], timeout: 1.5)
        defer { rig.close() }
        #expect(await Self.thoughtTaken(rig))
        #expect(await eventually { rig.details("ambient_duck_summary") == [Self.sent] })
        #expect(await rig.env.rig.adapter.contexts.count == 1)
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1",
                                                "on=false reason=timeout reported=1"])
    }

    /// The device's end (H-4) sends one too; the summary's reply text, named by its request, is kept for a save.
    @Test func theDeviceEndSendsOneSummaryAndItsReplyIsKept() async throws {
        let rig = try await Self.rig([])
        defer { rig.close() }
        #expect(await Self.thoughtTaken(rig))
        let connection = try #require(rig.connection()), router = rig.env.router
        router.ambientDuckEnd(connection: connection)
        #expect(await eventually { rig.details("ambient_duck_summary") == [Self.sent] })
        let context = try #require(await rig.env.rig.adapter.contexts.first)
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                    requestID: context.id)
        router.observeReply(Frame(timestamp: 0, target: RecipientTestRig.target, source: "host",
                                  payload: .text(TextPayload(text: "A <b> summary.", reply: reply))))
        // Another reply is not the summary's.
        let other = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                    requestID: UUID())
        router.observeReply(Frame(timestamp: 0, target: RecipientTestRig.target, source: "host",
                                  payload: .text(TextPayload(text: "Something else.", reply: other))))
        // Kept made inert: "A &lt;b> summary." is 17 bytes, the raw text 14.
        #expect(rig.details("ambient_duck_summary") == [Self.sent, "outcome=kept bytes=17"])
        await rig.finish()
        #expect(rig.details("ambient_duck").last == "on=false reason=device reported=1")
    }

    /// Media mode ends duck mode with no summary: it would be spoken over what is playing.
    @Test func mediaModeEndsItWithoutASummary() async throws {
        let rig = try await Self.rig([])
        defer { rig.close() }
        #expect(await Self.thoughtTaken(rig))
        let connection = try #require(rig.connection())
        #expect(rig.env.router.setMedia(true, connection: connection, reason: "voice") == 1)
        await rig.finish()
        #expect(rig.details("ambient_duck").last == "on=false reason=voice reported=1")
        #expect(rig.details("ambient_duck_summary").isEmpty)
        #expect(await rig.env.rig.adapter.contexts.isEmpty)
    }

    /// A retired stream (here the connection's end) drops the owner's held words at once, before its child is
    /// reaped: the summary's reply arriving then is kept nowhere.
    @Test func retiringTheStreamDropsTheHoldAtOnce() async throws {
        let rig = try await Self.rig(["Rightyo, done thinking."], lingers: true)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck_summary") == [Self.sent] })
        let context = try #require(await rig.env.rig.adapter.contexts.first)
        let pipeline = try #require(rig.env.router.activePipeline), connection = try #require(rig.connection())
        rig.env.router.stop(connection: connection)
        // The child lingers two seconds after its input closes, so the run cannot have ended yet.
        #expect(rig.env.router.liveRuns == 1)
        #expect(pipeline.noteDuckReply(request: context.id, text: "A synthetic summary.") == nil)
        await rig.finish()
    }

    /// The owner's save writes the note to the destination the consumer resolved from `notes`, then "Saved." plays.
    @Test func aSaveGoesToTheNotesDestinationThenConfirms() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = directory.appendingPathComponent("Inbox.md")
        let rig = try await Self.rig([])
        defer { rig.close() }
        #expect(await Self.thoughtTaken(rig))
        let connection = try #require(rig.connection()), router = rig.env.router
        let save = try #require(Self.save(to: .markdown(inbox.path)))
        router.duckSave(on: connection, listener: rig.env.listener)(save)
        #expect(await eventually { !rig.details("ambient_duck_save").isEmpty })
        await rig.finish()
        #expect(rig.details("ambient_duck_save") == ["destination=notes outcome=saved turns=1 bytes=\(save.bytes) "
            + "summary=pending confirm=confirmsaved/0:sent"])
        let body = try String(contentsOf: inbox, encoding: .utf8)
        // One flattened list item, as every Markdown note.
        #expect(body.hasPrefix("- ") && body.hasSuffix("\n") && body.dropLast().contains("\n") == false)
        #expect(body.contains("Duck mode notes, 1 turns.") && body.contains(Self.thought))
    }

    /// The agent's summary text is made inert for a Markdown viewer; the owner's own words are not touched.
    @Test(arguments: [("<img src=x>", "&lt;img src=x>"), ("see ![a](u.png)", "see ! [a](u.png)"),
                      ("[[Secret note]]", "[ [Secret note]]"), ("[[[x", "[ [ [x"), ("![[Embed]]", "! [ [Embed]]"),
                      ("---\ntitle: x", "\\---\ntitle: x"), ("ok\n  ---", "ok\n\\  ---"),
                      ("a - b --- c", "a - b --- c")])
    func theSummaryTextIsMadeInert(_ raw: String, _ inert: String) {
        #expect(RightyoAmbientPipeline.inertSummary(raw) == inert)
    }

    /// A note for one synthetic turn, as "save that" would hand it over.
    static func save(to target: VoiceDestinations.Destination) -> DuckSave? {
        let session = DuckSession()
        session.begin()
        session.append(thought)
        return session.close().map { DuckSave($0, to: target) }
    }

    @Test func eachSummaryOutcomeHasItsClipAndCountsOnlyToken() {
        typealias Router = AmbientRightyoRouter
        #expect(Router.duckSummaryConfirmation(.sent(turns: 2, bytes: 40)) == (nil, "outcome=sent turns=2 bytes=40"))
        #expect(Router.duckSummaryConfirmation(.notSent) == (AmbientStopConfirmation.notSent, "outcome=not_sent"))
        #expect(Router.duckSummaryConfirmation(.failed) == (nil, "outcome=failed"))
        #expect(Router.duckSummaryConfirmation(.skipped) == (nil, "outcome=skipped"))
    }
}
#endif
