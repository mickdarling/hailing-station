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
    static func rig(_ ending: [String], timeout: TimeInterval = 30,
                    destinations: VoiceDestinations? = nil) async throws -> DuckRig {
        let script = try AmbientDuckCueWiringTests.script([thought, "Are you still listening?"] + ending)
        return try await DuckRig(script: script, clips: clips, timeout: timeout, destinations: destinations)
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
                                  payload: .text(TextPayload(text: "A synthetic summary.", reply: reply))))
        // Another reply is not the summary's.
        let other = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                    requestID: UUID())
        router.observeReply(Frame(timestamp: 0, target: RecipientTestRig.target, source: "host",
                                  payload: .text(TextPayload(text: "Something else.", reply: other))))
        #expect(rig.details("ambient_duck_summary") == [Self.sent, "outcome=kept bytes=20"])
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

    /// The owner's save writes the note to the `notes` Markdown file and nowhere else, then "Saved." plays.
    @Test func aSaveGoesToTheNotesDestinationThenConfirms() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = directory.appendingPathComponent("Inbox.md"), other = directory.appendingPathComponent("Other.md")
        let destinations = try VoiceDestinations(["Notes": .markdown(inbox.path), "Other": .markdown(other.path)])
        let rig = try await Self.rig([], destinations: destinations)
        defer { rig.close() }
        #expect(await Self.thoughtTaken(rig))
        let connection = try #require(rig.connection()), router = rig.env.router
        let save = try #require(Self.save())
        router.duckSave(on: connection, listener: rig.env.listener)(save)
        #expect(await eventually { !rig.details("ambient_duck_save").isEmpty })
        await rig.finish()
        #expect(rig.details("ambient_duck_save") == ["destination=notes outcome=saved turns=1 bytes=\(save.bytes) "
            + "summary=none confirm=confirmsaved/0:sent"])
        let body = try String(contentsOf: inbox, encoding: .utf8)
        #expect(body.hasPrefix("- ") && body.contains("Duck mode notes, 1 turns.") && body.contains(Self.thought))
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    /// Without a `notes` destination nothing is saved anywhere, and the owner hears so.
    @Test func withoutANotesDestinationNothingIsSaved() async throws {
        let rig = try await Self.rig([])
        defer { rig.close() }
        #expect(await Self.thoughtTaken(rig))
        let connection = try #require(rig.connection())
        rig.env.router.duckSave(on: connection, listener: rig.env.listener)(try #require(Self.save()))
        #expect(await eventually { !rig.details("ambient_duck_save").isEmpty })
        await rig.finish()
        #expect(rig.details("ambient_duck_save").first?.contains("outcome=no_destination") == true)
        #expect(rig.details("ambient_duck_save").first?.hasSuffix("confirm=confirmnotsaved/0:sent") == true)
    }

    /// A note for one synthetic turn, as "save that" would hand it over.
    static func save() -> DuckSave? {
        let session = DuckSession()
        session.begin()
        session.append(thought)
        return session.close().map(DuckSave.init)
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
