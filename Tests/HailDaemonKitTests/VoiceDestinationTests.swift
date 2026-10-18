#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's spoken note to an allowlisted destination (#552, slice 1). Synthetic only; no real Shortcut runs.
@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceDestinationTests {
    static let names: Set<String> = ["jarvis", "rightyo"]
    static func destinations() throws -> VoiceDestinations {
        try VoiceDestinations(["Notes": .shortcut("Hail to Notes"),
                               "Shopping list": .shortcut("Hail to Groceries")])
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
        #expect(try VoiceDestinations.load(file)?.destinations["notes"] == .shortcut("Hail to Notes"))
        for (body, error) in [(#"{"notes": {"shortcut": "x", "send": "y"}}"#, VoiceDestinations.LoadError.malformed),
                              ("not json", .malformed), (#"{"notes": {"shortcut": "-h"}}"#, .invalidShortcut),
                              (#"{"!!": {"shortcut": "x"}}"#, .invalidName)] {
            try Data(body.utf8).write(to: file)
            #expect(throws: error) { try VoiceDestinations.load(file) }
        }
    }

    /// Only a private regular file is trusted: anyone else able to write it could rebind "notes" to any Shortcut.
    @Test func aFileOthersCouldWriteOrThatIsNotARegularFileIsUnsafe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("destinations.json")
        try Data(#"{"notes": {"shortcut": "Hail to Notes"}}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: file.path)
        #expect(throws: VoiceDestinations.LoadError.unsafe) { try VoiceDestinations.load(file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        #expect(throws: VoiceDestinations.LoadError.unsafe) { try VoiceDestinations.load(file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(try VoiceDestinations.load(file) != nil)
        let fifo = directory.appendingPathComponent("fifo.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: VoiceDestinations.LoadError.unsafe) { try VoiceDestinations.load(fifo) }
        let big = directory.appendingPathComponent("big.json")
        try Data(count: 64 * 1024 + 1).write(to: big)
        #expect(throws: VoiceDestinations.LoadError.unsafe) { try VoiceDestinations.load(big) }
        let remote = try #require(URL(string: "https://example.invalid/destinations.json"))
        #expect(throws: VoiceDestinations.LoadError.unsafe) { try VoiceDestinations.load(remote) }
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
            + #"/usr/bin/stat -f %Lp "$4" > mode.txt; echo "$4" > path.txt; /usr/bin/env | /usr/bin/sort > env.txt"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await runner.run("Hail to Notes", text: "buy milk; rm -rf ~") == "saved")
        let read = { (name: String) in try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) }
        #expect(try read("input.txt") == "buy milk; rm -rf ~")
        #expect(try read("mode.txt") == "600\n")
        #expect(try read("argv.txt").hasPrefix("run\nHail to Notes\n--input-path\n"))
        // Only the fixed child environment (the shell itself may add PWD, SHLVL and _).
        let names = Set(try read("env.txt").split(separator: "\n").compactMap { $0.split(separator: "=").first }
            .map(String.init)).subtracting(["PWD", "SHLVL", "_", "OLDPWD"])
        #expect(names.isSubset(of: ["PATH", "HOME", "TMPDIR"]))
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
        let both = try VoiceDestinations(["notes": .shortcut("A"), "notes app": .shortcut("B")])
        #expect(both.command(in: "add to notes app: x", names: [])?.target == .shortcut("B"))
        #expect(throws: VoiceDestinations.LoadError.invalidName) {
            try VoiceDestinations(["Notes": .shortcut("A"), "notes": .shortcut("B")])
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
        configuration.onVoiceDestination = { key, target, text in
            notes.withLock { $0.append("\(key)|\(target)|\(text)") }
        }
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        pipeline.finishInput()
        #expect(try await pipeline.run().delivered == (enrolled ? 0 : 1))
        #expect(notes.withLock { $0 } == (enrolled ? ["notes|shortcut(\"Hail to Notes\")|buy milk."] : []))
    }
}

extension VoiceDestinationTests {
    /// A Markdown destination names one absolute `.md` file; any other path, or two handlers at once, is refused.
    @Test func aMarkdownDestinationIsOneAbsoluteMarkdownFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("destinations.json")
        try Data(#"{"Notes": {"markdown": "/Users/me/Obsidian/Inbox.md"}}"#.utf8).write(to: file)
        #expect(try VoiceDestinations.load(file)?.destinations["notes"] == .markdown("/Users/me/Obsidian/Inbox.md"))
        for path in ["Inbox.md", "~/Inbox.md", "/a/Inbox.txt", "/a/../Inbox.md", "/a//Inbox.md", "/a/./Inbox.md", ""] {
            #expect(throws: VoiceDestinations.LoadError.invalidFile) {
                try VoiceDestinations(["notes": .markdown(path)])
            }
        }
        for body in [#"{"notes": {"markdown": "/a/Inbox.md", "shortcut": "x"}}"#, #"{"notes": {}}"#,
                     #"{"notes": {"markdown": 5}}"#, #"{"notes": {"word": "/a/Inbox.md"}}"#] {
            try Data(body.utf8).write(to: file)
            #expect(throws: VoiceDestinations.LoadError.malformed) { try VoiceDestinations.load(file) }
        }
        let note = try VoiceDestinations(["notes": .markdown("/a/Inbox.md")])
            .command(in: "add to notes milk", names: [])
        #expect(note?.target == .markdown("/a/Inbox.md") && note?.text == "milk")
    }
}
#endif
