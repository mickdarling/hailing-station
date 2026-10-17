#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's spoken note to an allowlisted destination (#552, slice 1). Synthetic only; no real Shortcut runs.
@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceDestinationTests {
    static let names: Set<String> = ["jarvis", "rightyo"]
    static func destinations() throws -> VoiceDestinations {
        try VoiceDestinations(["Notes": .init(shortcut: "Hail to Notes"),
                               "Shopping list": .init(shortcut: "Hail to Groceries")])
    }

    @Test(arguments: [
        ("Jarvis, add to Notes: Buy oat milk.", "notes", "Buy oat milk."),
        ("put this in notes buy milk", "notes", "buy milk"),
        ("Hey Jarvis, put that into shopping list - eggs, two dozen", "shoppinglist", "eggs, two dozen"),
        ("Rightyo add to Notes, call Dr. Lee at 3", "notes", "call Dr. Lee at 3")
    ])
    func aNoteKeepsItsWordsAsSaid(_ heard: String, _ destination: String, _ text: String) throws {
        let note = try Self.destinations().command(in: heard, names: Self.names)
        #expect(note?.destination == destination && note?.text == text)
    }

    @Test(arguments: [
        "Jarvis, add to Slack: ship it", "Jarvis, add to Notes", "Jarvis, add to Notes:  ", "Can you add to notes milk",
        "Siri, add to notes milk", "Please add to notes milk", "Jarvis, what's in my notes?", "Add notes milk",
        "Jarvis, add to notes.md a section on retries", "put this in notes/todo.txt"
    ])
    func anythingElseIsNotANote(_ heard: String) throws {
        #expect(try Self.destinations().command(in: heard, names: Self.names) == nil)
    }

    @Test func anOverlongNoteIsARequest() throws {
        let long = "add to notes " + String(repeating: "a", count: VoiceDestinations.maxText + 1)
        #expect(try Self.destinations().command(in: long, names: []) == nil)
    }

    @Test func theFileIsOffWhenAbsentAndStrictWhenPresent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("destinations.json")
        #expect(try VoiceDestinations.load(file) == nil)
        try Data(#"{"Notes": {"shortcut": "Hail to Notes"}}"#.utf8).write(to: file)
        #expect(try VoiceDestinations.load(file)?.destinations["notes"]?.shortcut == "Hail to Notes")
        for (body, error) in [(#"{"notes": {"shortcut": "x", "send": "y"}}"#, VoiceDestinations.LoadError.malformed),
                              ("not json", .malformed), (#"{"notes": {"shortcut": "-h"}}"#, .invalidShortcut),
                              (#"{"!!": {"shortcut": "x"}}"#, .invalidName)] {
            try Data(body.utf8).write(to: file)
            #expect(throws: error) { try VoiceDestinations.load(file) }
        }
    }

    /// A fake `shortcuts` that saves its argv and its input, then exits as told.
    private func runner(_ script: String, timeout: Duration = .seconds(20)) throws -> (ShortcutRunner, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fake = directory.appendingPathComponent("shortcuts")
        try Data("#!/bin/sh\ncd '\(directory.path)'\n\(script)\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        return (ShortcutRunner(executable: fake, timeout: timeout), directory)
    }

    @Test func theShortcutGetsTheWordsInAPrivateFileThatIsThenRemoved() async throws {
        let (runner, directory) = try runner(#"printf '%s\n' "$@" > argv.txt; /bin/cat "$4" > input.txt; "#
            + #"/usr/bin/stat -f %Lp "$4" > mode.txt; echo "$4" > path.txt"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await runner.run("Hail to Notes", text: "buy milk; rm -rf ~") == "saved")
        let read = { (name: String) in try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) }
        #expect(try read("input.txt") == "buy milk; rm -rf ~")
        #expect(try read("mode.txt") == "600\n")
        #expect(try read("argv.txt").hasPrefix("run\nHail to Notes\n--input-path\n"))
        let input = try read("path.txt").trimmingCharacters(in: .newlines)
        #expect(!FileManager.default.fileExists(atPath: input))
    }

    @Test func aFailingOrHungShortcutIsReportedNotSaved() async throws {
        let (failing, one) = try runner("exit 3")
        defer { try? FileManager.default.removeItem(at: one) }
        #expect(await failing.run("Hail to Notes", text: "x") == "exit_3")
        let (hung, two) = try runner("exec /bin/sleep 30", timeout: .seconds(1))
        defer { try? FileManager.default.removeItem(at: two) }
        #expect(await hung.run("Hail to Notes", text: "x") == "timeout")
        // One that ignores SIGTERM is killed after the grace, so the run still ends.
        let (stubborn, three) = try runner("trap '' TERM; /bin/sleep 30", timeout: .seconds(1))
        defer { try? FileManager.default.removeItem(at: three) }
        #expect(await stubborn.run("Hail to Notes", text: "x") == "timeout")
    }

    @Test func aCancelledRunStopsTheShortcut() async throws {
        let (runner, directory) = try runner("echo $$ > pid.txt; exec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = Task { await runner.run("Hail to Notes", text: "x") }
        let pidFile = directory.appendingPathComponent("pid.txt")
        #expect(await eventually { FileManager.default.fileExists(atPath: pidFile.path) })
        run.cancel()
        #expect(await run.value == "cancelled")
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .newlines)))
        #expect(await eventually { kill(pid, 0) != 0 })
    }

    @Test func theLongestNameWinsAndNamesMustBeDistinct() throws {
        let both = try VoiceDestinations(["notes": .init(shortcut: "A"), "notes app": .init(shortcut: "B")])
        #expect(both.command(in: "add to notes app: x", names: [])?.shortcut == "B")
        #expect(throws: VoiceDestinations.LoadError.invalidName) {
            try VoiceDestinations(["Notes": .init(shortcut: "A"), "notes": .init(shortcut: "B")])
        }
    }

    /// Only the enrolled owner's note is held back; on an anonymous session it is a request like any other.
    @Test(arguments: [true, false]) func onlyTheEnrolledOwnersNoteIsHandedToTheHost(_ enrolled: Bool) async throws {
        let fake = try FakeRightyo(AmbientVoiceMuteTests.fixture(saying: "Rightyo, add to Notes: buy milk.",
                                                                 enrolled: enrolled))
        defer { fake.cleanUp() }
        try fake.install(fixture: enrolled ? "enrolled-formed-request.jsonl" : "tool-events.jsonl")
        let notes = Mutex<[String]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        configuration.destinations = try Self.destinations()
        configuration.onVoiceDestination = { key, shortcut, text in
            notes.withLock { $0.append("\(key)|\(shortcut)|\(text)") }
        }
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        pipeline.finishInput()
        #expect(try await pipeline.run().delivered == (enrolled ? 0 : 1))
        #expect(notes.withLock { $0 } == (enrolled ? ["notes|Hail to Notes|buy milk."] : []))
    }
}
#endif
