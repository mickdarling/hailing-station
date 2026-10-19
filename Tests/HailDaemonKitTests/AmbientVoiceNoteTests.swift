#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's spoken note (#552) end to end through the listener: its handler saves the words, and
/// only then does the device hear whether it saved. Synthetic only: a fake `shortcuts` or a temporary file.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientVoiceNoteTests {
    static let saved = AmbientAckClip(pcm: Data(repeating: 7, count: 480), sampleRate: 24_000, text: "Saved.")
    static let notSaved = AmbientAckClip(pcm: Data(repeating: 8, count: 480), sampleRate: 24_000,
                                         text: "That didn't save.")

    @Test(arguments: [(0, "Saved.", "saved", "confirmsaved"), (3, "That didn't save.", "exit_3", "confirmnotsaved")])
    func aNoteRunsItsShortcutThenConfirms(_ exit: Int, _ words: String, _ outcome: String, _ folder: String)
        async throws {
        let fake = try FakeRightyo(AmbientWiringVoiceMuteTests.fixture(saying: "Rightyo, add to Notes: buy milk.",
                                                                 enrolled: true))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shortcuts = directory.appendingPathComponent("shortcuts")
        try Data("#!/bin/sh\n/bin/cat \"$4\" > '\(directory.path)/note.txt'\nexit \(exit)\n".utf8).write(to: shortcuts)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shortcuts.path)
        let details = Mutex<[String]>([])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20),
            acknowledgements: AmbientAckLibrary(clips: ["confirmsaved": [Self.saved],
                                                        "confirmnotsaved": [Self.notSaved]]),
            destinations: try VoiceDestinations(["Notes": .shortcut("Hail to Notes")]),
            shortcuts: ShortcutRunner(executable: shortcuts, timeout: .seconds(20)),
            onEvent: { event in
                if event.event == "ambient_voice_note" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let (session, socket) = try await Self.connect(env)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: socket)
        let text = try await receiveFrame(on: socket, step: "confirmation words")
        guard case .text(let heard) = text.payload else {
            Issue.record("expected the confirmation")
            return
        }
        #expect(heard.text == words)
        #expect(await eventually { details.withLock { !$0.isEmpty } })
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        #expect(details.withLock { $0 } == ["destination=notes outcome=\(outcome) bytes=9 confirm=\(folder)/0:sent"])
        #expect(try String(contentsOf: directory.appendingPathComponent("note.txt"), encoding: .utf8) == "buy milk.")
    }

    /// A Markdown destination needs no Shortcut: the words are appended to the owner's file, then "Saved." plays.
    @Test func aNoteToAMarkdownFileIsAppendedThenConfirmed() async throws {
        let fake = try FakeRightyo(AmbientWiringVoiceMuteTests.fixture(saying: "Rightyo, add to Notes: buy milk.",
                                                                 enrolled: true))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = directory.appendingPathComponent("Inbox.md")
        let details = Mutex<[String]>([])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20),
            acknowledgements: AmbientAckLibrary(clips: ["confirmsaved": [Self.saved]]),
            destinations: try VoiceDestinations(["Notes": .markdown(inbox.path)]),
            onEvent: { event in
                if event.event == "ambient_voice_note" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let (session, socket) = try await Self.connect(env)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: socket)
        let text = try await receiveFrame(on: socket, step: "confirmation words")
        guard case .text(let heard) = text.payload else {
            Issue.record("expected the confirmation")
            return
        }
        #expect(heard.text == "Saved.")
        #expect(await eventually { details.withLock { !$0.isEmpty } })
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        #expect(details.withLock { $0 } == ["destination=notes outcome=saved bytes=9 confirm=confirmsaved/0:sent"])
        let body = try String(contentsOf: inbox, encoding: .utf8)
        #expect(body.hasPrefix("- ") && body.hasSuffix(" buy milk.\n"))
    }
}

extension AmbientVoiceNoteTests {
    /// A device that said hello and selected the rig's target.
    static func connect(_ env: AmbientWiringRig) async throws -> (URLSession, URLSessionWebSocketTask) {
        let (session, socket) = try recipientSocket(port: env.port)
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: [], deviceName: "test"
        )))), on: socket)
        _ = try await recipientSocketReceive(on: socket)
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await recipientSocketBarrier(on: socket)
        return (session, socket)
    }
}
#endif
