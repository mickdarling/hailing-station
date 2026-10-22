#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Duck mode's end through the ambient pipeline (#735 H-5): the host turns duck mode off, the owner's session is
/// summarised once through the stream's own delivery step without an acknowledgement, its turns are held, and the
/// owner's "save that" request hands them to the host instead of the agent. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckSummaryTests {
    static let summaryOwner = UUID()

    /// The owner's (or `role`'s) whole request for `text` at `sequence`: transcript, attention and request lines,
    /// as a RightyO out of duck mode sends them (session `formed-demo`, rewritten by the script).
    static func request(_ text: String, sequence: Int, role: String = "owner") throws -> [String] {
        let at = 2_000 + sequence * 100, id = "duck-\(sequence)"
        let transcript = try AmbientDuckBufferTests.transcript(text, sequence: sequence, role: role)
        let turn = try #require(JSONSerialization.jsonObject(with: Data(transcript.utf8)) as? [String: Any])["turn"]
        let decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1", "role": role]
        let common: [String: Any] = ["schema_version": 1, "session_id": "formed-demo", "emitted_at_ms": at + 1]
        let attention = common.merging(["type": "attention", "sequence": sequence + 1, "utterance_id": id,
                                        "request_id": "formed-demo:\(id)", "decision": decision]) { $1 }
        let request = common.merging(["type": "request", "sequence": sequence + 2, "request_id": "formed-demo:\(id)",
                                      "turn": turn as Any, "decision": decision, "context": ["turns": []],
                                      "decision_at_ms": at + 1]) { $1 }
        return try [transcript] + [attention, request].map { line in
            try #require(String(bytes: JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
                                encoding: .utf8))
        }
    }

    /// Replays `phase1.jsonl` (started and the ducking turns), waits for the test's `go` file, replays `phase2.jsonl`,
    /// then emits `stopped` once the audio ends.
    static let script = """
    /usr/bin/sed -e "s/formed-demo/$7/g" phase1.jsonl
    while [ ! -f go ]; do /bin/sleep 0.02; done
    /usr/bin/sed -e "s/formed-demo/$7/g" phase2.jsonl
    /bin/cat > /dev/null
    /usr/bin/sed -e "s/formed-demo/$7/g" stopped.jsonl
    """

    struct Seen {
        var requests: [LocalDispatchRequest] = []
        var summaries: [DuckSummaryOutcome] = []
        var saves: [DuckSave] = []
        var acknowledged = 0
        var keptAfterEnd = true
    }

    /// A fake RightyO with its three phases written: the ducking turns and the owner's exit, `after`, `stopped`.
    static func install(_ words: [(String, String)], after: [String]) throws -> FakeRightyo {
        let fake = try FakeRightyo(script)
        let phase1 = try AmbientDuckBufferTests.events(words + [("Rightyo, done thinking.", "owner")])
            .split(separator: "\n").dropLast()
        try Data((phase1.joined(separator: "\n") + "\n").utf8)
            .write(to: fake.directory.appendingPathComponent("phase1.jsonl"))
        try Data((after.joined(separator: "\n") + (after.isEmpty ? "" : "\n")).utf8)
            .write(to: fake.directory.appendingPathComponent("phase2.jsonl"))
        let stopped = #"{"emitted_at_ms": 9000, "phase": "stopped", "schema_version": 1, "sequence": 99, "#
            + #""session_id": "formed-demo", "type": "session"}"# + "\n"
        try Data(stopped.utf8).write(to: fake.directory.appendingPathComponent("stopped.jsonl"))
        return fake
    }

    /// Runs one stream: duck mode on, the owner's `words` while ducking, the owner's exit (the host then turns duck
    /// mode off with `summarize`), then, once any summary is reported (or at once without one), `after`.
    private func run(_ words: [(String, String)], summarize: Bool = true, after: [String] = [],
                     refusal: LocalDispatchRefusal? = nil, reply: String? = nil) async throws -> Seen {
        let fake = try Self.install(words, after: after)
        defer { fake.cleanUp() }
        let go = fake.directory.appendingPathComponent("go")
        let seen = Mutex(Seen()), box = Mutex<RightyoAmbientPipeline?>(nil)
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            onAcknowledge: { _ in seen.withLock { $0.acknowledged += 1 } }
        )
        configuration.replyControl = true
        // As the host does: the owner's exit turns duck mode off, here with or without a summary.
        configuration.onVoiceDuck = { command in
            guard command == .off, let pipeline = box.withLock({ $0 }) else { return }
            pipeline.reportDuck(false, summarize: summarize)
            if !summarize { FileManager.default.createFile(atPath: go.path, contents: nil) }
        }
        configuration.onDuckSummary = { outcome in
            seen.withLock { $0.summaries.append(outcome) }
            if let reply, let pipeline = box.withLock({ $0 }) {
                _ = pipeline.noteDuckReply(request: Self.summaryOwner, text: reply)
            }
            FileManager.default.createFile(atPath: go.path, contents: nil)
        }
        configuration.onDuckSave = { save in seen.withLock { $0.saves.append(save) } }
        let dispatcher = RecordingAmbientDispatcher(owner: Self.summaryOwner, refusal: refusal)
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        box.withLock { $0 = pipeline }
        pipeline.reportDuck(true)
        // An empty session sends nothing, so nothing would ever open the gate.
        if words.allSatisfy({ $0.1 != "owner" }) { FileManager.default.createFile(atPath: go.path, contents: nil) }
        pipeline.finishInput()
        _ = try await pipeline.run()
        let requests = await dispatcher.requests
        let kept = pipeline.noteDuckReply(request: Self.summaryOwner, text: "Late.")
        return seen.withLock { seen in
            (seen.requests, seen.keptAfterEnd) = (requests, kept)
            return seen
        }
    }

    @Test func theExitSendsOneSummaryWithoutAnAcknowledgement() async throws {
        let seen = try await run([("First synthetic thought.", "owner"), ("Guest synthetic words.", "participant"),
                                  ("Second synthetic thought.", "owner")])
        #expect(seen.requests.count == 1 && seen.acknowledged == 0)
        let request = try #require(seen.requests.first)
        #expect(request.target == "tmux:demo" && request.binding == "pinned")
        #expect(request.text.hasSuffix(RightyoInputEvent.duckSummaryReplyBlock(target: "tmux:demo")))
        #expect(request.text.contains("First synthetic thought.") && request.text.contains("Second synthetic thought."))
        #expect(!request.text.contains("Guest synthetic") && !request.text.contains("done thinking"))
        let bytes = "First synthetic thought.Second synthetic thought.".utf8.count
        #expect(seen.summaries == [.sent(turns: 2, bytes: bytes)])
        // The stream's end dropped the hold: a reply arriving afterwards is kept nowhere.
        #expect(!seen.keptAfterEnd)
    }

    /// "Save that" after the summary: the note carries the summary's spoken text and the turns, goes to the host
    /// alone, and is neither sent nor acknowledged.
    @Test func aSaveCarriesTheSummarysTextAndTheTurns() async throws {
        let save = try Self.request("Rightyo, save that.", sequence: 10)
        let seen = try await run([("A synthetic thought.", "owner")], after: save, reply: "A synthetic summary.")
        #expect(seen.requests.count == 1 && seen.acknowledged == 0)
        let note = try #require(seen.saves.first)
        #expect(seen.saves.count == 1 && note.summary == "captured" && note.turns == 1)
        #expect(note.text.contains("Summary: A synthetic summary.") && note.text.contains("- A synthetic thought."))
    }

    /// Media mode or a child that cannot take duck mode ends it without a summary; the turns are still held.
    @Test func withoutASummaryNothingIsSentAndTheTurnsAreStillHeld() async throws {
        let save = try Self.request("Save that to notes.", sequence: 10)
        let seen = try await run([("A synthetic thought.", "owner")], summarize: false, after: save)
        #expect(seen.requests.isEmpty && seen.summaries.isEmpty && seen.acknowledged == 0)
        #expect(seen.saves.map(\.summary) == ["none"])
        #expect(seen.saves.first?.text.contains("A synthetic thought.") == true)
    }

    /// An empty session sends no summary, and with nothing held "save that" is an ordinary request.
    @Test func anEmptySessionSendsNothingAndSaveIsARequest() async throws {
        let save = try Self.request("Rightyo, save that.", sequence: 10)
        let seen = try await run([("Guest synthetic words.", "participant")], after: save)
        #expect(seen.summaries.isEmpty && seen.saves.isEmpty)
        #expect(seen.requests.count == 1 && seen.acknowledged == 1)
        #expect(seen.requests.first?.text.contains("save that") == true)
    }

    /// A guest's "save that" is a request like any other: nothing of the owner's is saved.
    @Test func aGuestsSaveIsARequest() async throws {
        let save = try Self.request("Save that.", sequence: 10, role: "participant")
        let seen = try await run([("A synthetic thought.", "owner")], after: save)
        #expect(seen.saves.isEmpty && seen.requests.count == 2 && seen.acknowledged == 1)
    }

    /// A guard or policy refusal is reported, and the stream goes on.
    @Test func aRefusedSummaryIsReported() async throws {
        let seen = try await run([("A synthetic thought.", "owner")], refusal: .confirmationRequired)
        #expect(seen.summaries == [.notSent] && seen.requests.count == 1)
    }

    /// The control closes the session on the off and returns its hold; `discard` drops it.
    @Test func theControlHoldsOnTheOffAndDiscardDropsIt() throws {
        let session = DuckSession(), control = AmbientDuckControl(session: session)
        #expect(control.change(true) { _ in true }.closed == nil)
        session.append("A synthetic turn.")
        #expect(control.change(true) { _ in true }.closed == nil)
        let closed = try #require(control.change(false) { _ in true }.closed)
        #expect(closed.copy.turns == ["A synthetic turn."] && session.held == closed)
        #expect(control.change(false) { _ in true }.closed == nil && session.held == closed)
        control.discard()
        #expect(session.held == nil)
    }
}
#endif
