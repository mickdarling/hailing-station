#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

struct EnrollmentFixture: Sendable {
    let root: URL, file: URL, executable: URL, directory: URL
    var manifest: URL { directory.appendingPathComponent(SelfVoiceManifest.name) }
    static let voice = ["id": "one", "profile": "Local (one)", "source": "reply",
                        "revision": "1", "endpoint": "http://127.0.0.1:1234"]

    init() throws {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let temporary = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        root = temporary.appendingPathComponent(UUID().uuidString)
        file = root.appendingPathComponent("voices.json")
        executable = root.appendingPathComponent("vbsay")
        directory = root.appendingPathComponent("self-voice")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        // Inert fixture. Tests inject a renderer and never execute this file.
        try Data().write(to: executable)
        try #require(chmod(executable.path, 0o700) == 0)
        try write()
        try #require(try load().voices == [voiceFixture()])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ voices: [[String: String]] = [voice], path: String? = nil) throws {
        try write(object: ["version": 1, "vbsay": path ?? executable.path, "voices": voices])
    }

    func write(object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        try #require(chmod(file.path, 0o600) == 0)
    }

    func readManifest() throws -> SelfVoiceManifest {
        try JSONDecoder().decode(SelfVoiceManifest.self, from: Data(contentsOf: manifest))
    }

    func load() throws -> SelfVoiceEnrollment { try SelfVoiceEnrollment.load(file.path) }
}

struct SelfVoiceEnrollmentTests {
    typealias Failure = SelfVoiceEnrollment.Failure

    @Test func acceptsReplyAndExplicitEmptyList() throws {
        let fixture = try EnrollmentFixture()
        defer { fixture.remove() }
        let loaded = try fixture.load()
        #expect(loaded.executable.path == fixture.executable.path)
        #expect(loaded.voices == [voiceFixture()])
        try fixture.write([])
        #expect(try fixture.load().voices.isEmpty)
    }

    @Test(arguments: [0o644, 0o640, 0o700])
    func rejectsNonPrivateFileMode(mode: Int) throws {
        let fixture = try EnrollmentFixture()
        defer { fixture.remove() }
        try #require(chmod(fixture.file.path, mode_t(mode)) == 0)
        #expect(throws: Failure.file) { try fixture.load() }
    }

    @Test func rejectsRelativePathSymlinksAndHardLinks() throws {
        let fixture = try EnrollmentFixture()
        defer { fixture.remove() }
        #expect(throws: Failure.relativePath) { try SelfVoiceEnrollment.load("voices.json") }
        let alias = fixture.root.appendingPathComponent("alias")
        try #require(symlink(fixture.file.path, alias.path) == 0)
        #expect(throws: Failure.file) { try SelfVoiceEnrollment.load(alias.path) }
        try #require(unlink(alias.path) == 0)
        try #require(symlink(fixture.root.path, alias.path) == 0)
        #expect(throws: Failure.file) { try SelfVoiceEnrollment.load(alias.appendingPathComponent("voices.json").path) }
        try #require(unlink(alias.path) == 0)
        try #require(link(fixture.file.path, alias.path) == 0)
        #expect(throws: Failure.file) { try fixture.load() }
    }

    @Test func rejectsExtendedACLForeignOwnerAndOversize() throws {
        let fixture = try EnrollmentFixture()
        defer { fixture.remove() }
        try CodexLauncherTests.addACL("everyone deny delete", to: fixture.file.path)
        #expect(throws: Failure.file) { try fixture.load() }
        CodexLauncherTests.clearACLs(fixture.file.path)
        var info = stat()
        try #require(lstat(fixture.file.path, &info) == 0)
        try SelfVoicePrivateFile.requirePrivate(info, type: S_IFREG, hasACL: false)
        info.st_uid ^= 1
        #expect(throws: SelfVoiceError.directory) {
            try SelfVoicePrivateFile.requirePrivate(info, type: S_IFREG, hasACL: false)
        }
        var padded = try Data(contentsOf: fixture.file)
        padded.append(Data(repeating: 32, count: 16_384 - padded.count))
        try padded.write(to: fixture.file)
        #expect(try fixture.load().voices == [voiceFixture()])
        try (padded + Data([32])).write(to: fixture.file)
        #expect(throws: Failure.size) { try fixture.load() }
    }

    @Test func requiresExactKeysAndVersion() throws {
        let fixture = try EnrollmentFixture()
        defer { fixture.remove() }
        let valid: [String: Any] = ["version": 1, "vbsay": fixture.executable.path, "voices": [EnrollmentFixture.voice]]
        for key in valid.keys {
            var object = valid
            object.removeValue(forKey: key)
            try fixture.write(object: object)
            #expect(throws: Failure.schema) { try fixture.load() }
        }
        try fixture.write(object: valid.merging(["extra": 0]) { $1 })
        #expect(throws: Failure.schema) { try fixture.load() }
        for version: Any in [2 as Any, true, "1"] {
            try fixture.write(object: valid.merging(["version": version]) { $1 })
            #expect(throws: Failure.version) { try fixture.load() }
        }
        var duplicate = Data(#"{"version":1,"#.utf8)
        duplicate.append(try JSONSerialization.data(withJSONObject: valid).dropFirst())
        try duplicate.write(to: fixture.file)
        #expect(throws: Failure.schema) { try fixture.load() }
        let voice = EnrollmentFixture.voice
        for key in voice.keys {
            try fixture.write([voice.filter { $0.key != key }])
            #expect(throws: Failure.schema) { try fixture.load() }
        }
        try fixture.write([voice.merging(["unknown": "value"]) { $1 }])
        #expect(throws: Failure.schema) { try fixture.load() }
    }

    @Test func enforcesReplyOriginAndIDRules() throws {
        let fixture = try EnrollmentFixture()
        defer { fixture.remove() }
        let voice = EnrollmentFixture.voice
        for invalid in [["source": "ack"], ["endpoint": "http://192.0.2.1:80"], ["endpoint": "http://[::1]:80"],
                        ["endpoint": "http://localhost:80"], ["endpoint": "http://127.0.0.1:80/"]] {
            try fixture.write([voice.merging(invalid) { $1 }])
            #expect(throws: Failure.voice) { try fixture.load() }
        }
        let seventeen = (0..<17).map { index in voice.merging(["id": "v\(index)"]) { $1 } }
        for invalid in [[voice, voice], seventeen, [voice.merging(["id": "bad/id"]) { $1 }]] {
            try fixture.write(invalid)
            #expect(throws: Failure.ids) { try fixture.load() }
        }
    }

    @Test func rejectsUntrustedExecutableEvenForEmptyEnrollment() throws {
        let fixture = try EnrollmentFixture()
        defer { fixture.remove() }
        let bin = fixture.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let moved = bin.appendingPathComponent("vbsay")
        try FileManager.default.moveItem(at: fixture.executable, to: moved)
        try fixture.write([], path: moved.path)
        #expect(try fixture.load().executable.path == moved.path)
        try #require(symlink(moved.path, fixture.executable.path) == 0)
        let alias = fixture.root.appendingPathComponent("alias")
        try #require(symlink(bin.path, alias.path) == 0)
        for path in [fixture.executable.path, alias.appendingPathComponent("vbsay").path, "bin/vbsay"] {
            try fixture.write([], path: path)
            #expect(throws: Failure.executable) { try fixture.load() }
        }
        try fixture.write([], path: moved.path)
        for mode in [0o720, 0o600] {
            try #require(chmod(moved.path, mode_t(mode)) == 0)
            #expect(throws: Failure.executable) { try fixture.load() }
        }
        try #require(chmod(moved.path, 0o700) == 0 && chmod(bin.path, 0o720) == 0)
        #expect(throws: Failure.executable) { try fixture.load() }
    }
}
#endif
