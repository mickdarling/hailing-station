#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Spoken notes' Shortcut inputs (#552) live in haild's own `hail-notes/` folder: the startup sweep lists only that
/// folder, and runs off the startup path, so a crowded per-user temporary folder never holds `listener_ready`.
/// Synthetic files only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct VoiceNoteInputsTests {
    private static func scratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func note(_ url: URL, age: TimeInterval) throws {
        try Data("synthetic".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                              ofItemAtPath: url.path)
    }

    @Test func theSweepRemovesOnlyItsOwnFolderStaleInputs() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let inputs = VoiceNoteInputs(base: base)
        let first = try #require(inputs.newInput())
        #expect(first.deletingLastPathComponent().standardizedFileURL == inputs.folder.standardizedFileURL)
        let mode = try FileManager.default.attributesOfItem(atPath: inputs.folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        let topLevel = base.appendingPathComponent("hail-note-left-by-an-older-haild.txt")
        let stale = inputs.folder.appendingPathComponent("hail-note-stale.txt")
        let fresh = inputs.folder.appendingPathComponent("hail-note-fresh.txt")
        let other = inputs.folder.appendingPathComponent("other.txt")
        try Self.note(topLevel, age: 3600)
        try Self.note(stale, age: VoiceNoteInputs.maxAge + 60)
        try Self.note(fresh, age: 10)
        try Self.note(other, age: 3600)
        // The base cannot be listed, only traversed: a sweep that still listed it would remove nothing here.
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: base.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path) }
        inputs.sweep()
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        #expect(!exists(stale))
        #expect(exists(fresh) && exists(other) && exists(topLevel))
    }

    @Test func aFolderThatIsNotPrivateIsNeverUsedOrSwept() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let decoy = elsewhere.appendingPathComponent("hail-note-decoy.txt")
        try Self.note(decoy, age: 3600)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent(VoiceNoteInputs.folderName),
                                                   withDestinationURL: elsewhere)
        let inputs = VoiceNoteInputs(base: base)
        #expect(inputs.newInput() == nil)
        inputs.sweep()
        #expect(FileManager.default.fileExists(atPath: decoy.path))
    }

    @Test func theShortcutInputIsWrittenInTheNotesFolder() async throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let fake = base.appendingPathComponent("shortcuts")
        // It records the input's path and mode: the words are readable by the owner only (#804).
        try Data("#!/bin/sh\necho \"$4\" > '\(base.path)/path.txt'\nstat -f %Lp \"$4\" > '\(base.path)/mode.txt'\n"
            .utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let inputs = VoiceNoteInputs(base: base)
        let runner = ShortcutRunner(executable: fake, timeout: .seconds(20), inputs: inputs)
        #expect(await runner.run("Hail to Notes", text: "x") == "saved")
        let path = try String(contentsOf: base.appendingPathComponent("path.txt"), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
            == inputs.folder.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: path))
        let mode = try String(contentsOf: base.appendingPathComponent("mode.txt"), encoding: .utf8)
        #expect(mode.trimmingCharacters(in: .newlines) == "600")
    }

    /// #804: an input is swept only once no run could still be reading it, past the Shortcut's timeout and the 2 s
    /// grace before its SIGKILL.
    @Test func theSweepAgeOutlastsAnyShortcutRun() {
        #expect(Duration.seconds(VoiceNoteInputs.maxAge) > ShortcutRunner().timeout + .seconds(2))
    }

    /// The stall this guards: work handed to the background returns at once, however long the work takes.
    @Test func backgroundWorkNeverHoldsTheCaller() async {
        let release = DispatchSemaphore(value: 0), finished = Mutex(false)
        let task = VoiceNoteInputs.inBackground {
            _ = release.wait(timeout: .now() + 10)
            finished.withLock { $0 = true }
        }
        #expect(!finished.withLock { $0 })
        release.signal()
        await task.value
        #expect(finished.withLock { $0 })
    }

    /// Startup with spoken notes on returns its router and sweeps the notes folder in the background.
    @Test func startupSweepsTheNotesFolderOffItsPath() async throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let destinations = base.appendingPathComponent("destinations.json")
        try Data(#"{"Notes": {"shortcut": "Hail to Notes"}}"#.utf8).write(to: destinations)
        let inputs = VoiceNoteInputs(base: base)
        let stale = try #require(inputs.newInput())
        try Self.note(stale, age: VoiceNoteInputs.maxAge + 60)
        let rig = try await RecipientTestRig.make()
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        var options = ConnectionProbeDaemon.AmbientOptions(
            executable: fake.executable, config: fake.config, target: RecipientTestRig.target
        )
        (options.destinations, options.noteInputs) = (destinations, inputs)
        let router = try await ConnectionProbeDaemon.ambientRouter(options, host: rig.host, log: { _ in })
        #expect(router.configuration.destinations?.destinations.count == 1)
        #expect(await eventually { !FileManager.default.fileExists(atPath: stale.path) })
    }
}
#endif
