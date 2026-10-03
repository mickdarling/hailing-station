#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// A throwaway directory holding a fake `rightyo` behaviour, its config and whatever it records (#203). Every
/// fake shares one executable that sources `behavior.sh` from its working directory (the config's directory):
/// each freshly written executable pays a first-exec system check, and a dozen of them launched at once slowed
/// the other process suites past their deadlines. Only refused modes get a file of their own, never executed.
struct FakeRightyo {
    let directory: URL
    let executable: URL
    let config: URL

    static let shared: URL = {
        let directory = physical(FileManager.default.temporaryDirectory.appendingPathComponent(
            "fake-rightyo-shared-\(getpid())"))
        let executable = directory.appendingPathComponent("rightyo")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: executable.path) {
            try? Data("#!/bin/sh\n. ./behavior.sh\n".utf8).write(to: executable, options: .atomic)
            _ = chmod(executable.path, 0o755)
        }
        return executable
    }()

    /// The physical path (`/private/var/…`), as `pwd -P` reports it in the child.
    static func physical(_ url: URL) -> URL {
        let resolved = realpath(url.deletingLastPathComponent().path, nil)
        defer { free(resolved) }
        let parent = resolved.map { String(cString: $0) } ?? url.deletingLastPathComponent().path
        return URL(fileURLWithPath: parent).appendingPathComponent(url.lastPathComponent)
    }

    init(_ body: String, mode: mode_t = 0o755) throws {
        directory = Self.physical(FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-rightyo-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = directory.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: config)
        try Data("\(body)\n".utf8).write(to: directory.appendingPathComponent("behavior.sh"))
        #expect(chmod(directory.path, 0o700) == 0)
        if mode == 0o755 { executable = Self.shared } else {
            executable = directory.appendingPathComponent("rightyo")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            #expect(chmod(executable.path, mode) == 0)
        }
    }

    /// Copies a checked-in fixture next to the script as `events.jsonl`.
    func install(fixture name: String) throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/rightyo/\(name)")
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("events.jsonl"))
    }

    func recorded(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    /// Graceful exits get long graces: a cold script launch under a loaded parallel run can take over a second.
    func child(_ timing: RightyoChildProcess.Timing = .init(eofGrace: 20, termGrace: 20))
        throws -> RightyoChildProcess {
        try RightyoChildProcess(executable: executable, config: config, session: "hail-test", timing: timing)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

/// Generous limits: these suites spawn real processes beside every other parallel suite (#203).
@Suite(.timeLimit(.minutes(1))) struct RightyoChildProcessTests {
    @Test func launchesExactArgvMinimalEnvironmentAndConfigDirectory() async throws {
        let fake = try FakeRightyo("""
            printf '%s\\n' "$@" > argv.txt
            /usr/bin/env > env.txt
            /bin/pwd -P > cwd.txt
            """)
        defer { fake.cleanUp() }
        let child = try fake.child()
        #expect(await child.stop() == .exited(0))
        let argv = try fake.recorded("argv.txt").split(separator: "\n").map(String.init)
        #expect(argv == ["listen", "--mode", "stdin", "--provenance", "live-microphone",
                         "--session-id", "hail-test", "--config", fake.config.path])
        let keys = Set(try fake.recorded("env.txt").split(separator: "\n")
            .compactMap { $0.split(separator: "=").first })
        #expect(keys.isSubset(of: ["PATH", "HOME", "TMPDIR", "PWD", "SHLVL", "_", "OLDPWD"]))
        #expect(keys.contains("PATH"))
        #expect(try fake.recorded("cwd.txt") == fake.directory.path + "\n")
    }

    @Test func stopClosesStdinAfterQueuedAudioAndTheChildExitsOnEOF() async throws {
        let fake = try FakeRightyo("/usr/bin/wc -c | /usr/bin/tr -d ' ' > stdin-bytes.txt")
        defer { fake.cleanUp() }
        let child = try fake.child()
        for _ in 0..<10 { #expect(child.write(Data(repeating: 1, count: 3_200))) }
        #expect(await child.stop() == .exited(0))
        #expect(try fake.recorded("stdin-bytes.txt") == "32000\n")
        #expect(child.counters.writtenBytes == 32_000)
        #expect(child.counters.droppedChunks == 0)
        #expect(!child.write(Data(repeating: 1, count: 2)))
    }

    @Test func escalatesToSIGKILLWhenTheChildIgnoresEOFAndSIGTERM() async throws {
        let fake = try FakeRightyo("trap '' TERM\necho ready\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        let child = try fake.child(.init(eofGrace: 0.5, termGrace: 0.5))
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8)) // The trap is installed before this line.
        #expect(await child.stop() == .signaled(SIGKILL))
        #expect(child.exitStatus == .signaled(SIGKILL))
    }

    @Test func sigtermEndsAChildThatIgnoresEOF() async throws {
        let fake = try FakeRightyo("echo ready\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        let child = try fake.child(.init(eofGrace: 0.5, termGrace: 20))
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        #expect(await child.stop() == .signaled(SIGTERM))
    }

    @Test func aStalledChildDropsTheOldestAudioWithoutBlockingTheCaller() async throws {
        let fake = try FakeRightyo("echo ready\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        let child = try fake.child(.init(eofGrace: 0.5, termGrace: 20, backlogAge: 60))
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        let chunks = 200, size = 3_200
        for _ in 0..<chunks { #expect(child.write(Data(repeating: 7, count: size))) }
        let counters = child.counters
        // At most the backlog, one in-flight chunk and a full pipe can be held; everything else is dropped whole.
        #expect(counters.droppedBytes == counters.droppedChunks * size)
        #expect(counters.droppedBytes >= chunks * size - 65_536 - size - 65_536)
        #expect(await child.stop() == .signaled(SIGTERM))
    }

    @Test func refusesOversizedOddOrEmptyChunks() async throws {
        let fake = try FakeRightyo("/usr/bin/wc -c > /dev/null")
        defer { fake.cleanUp() }
        let child = try fake.child()
        #expect(!child.write(Data()))
        #expect(!child.write(Data(repeating: 0, count: 3)))
        #expect(!child.write(Data(repeating: 0, count: 65_538)))
        #expect(await child.stop() == .exited(0))
    }

    @Test func aStdoutLinePastTheCapEndsTheStream() async throws {
        let fake = try FakeRightyo("/bin/dd if=/dev/zero bs=1000 count=1300 2>/dev/null | /usr/bin/tr '\\0' a")
        defer { fake.cleanUp() }
        let child = try fake.child()
        await #expect(throws: RightyoChildError.lineTooLong) { for try await _ in child.lines {} }
        #expect(await child.stop() == .exited(0))
    }

    @Test func aLineAtTheCapIsDelivered() async throws {
        let fake = try FakeRightyo("/bin/dd if=/dev/zero bs=1000 count=1200 2>/dev/null | /usr/bin/tr '\\0' a; echo")
        defer { fake.cleanUp() }
        let child = try fake.child()
        var sizes: [Int] = []
        for try await line in child.lines { sizes.append(line.count) }
        #expect(sizes == [RightyoChildProcess.maxLineBytes])
        #expect(await child.stop() == .exited(0))
    }

    @Test func refusesUnsafeExecutablesAndConfigs() throws {
        for mode: mode_t in [0o775, 0o757, 0o644] {
            let fake = try FakeRightyo("exit 0", mode: mode)
            defer { fake.cleanUp() }
            #expect(throws: RightyoChildError.unsafeExecutable) { try fake.child() }
        }
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        let relative = URL(fileURLWithPath: "rightyo", relativeTo: fake.directory)
        #expect(throws: RightyoChildError.unsafeExecutable) {
            try RightyoChildProcess.validate(executable: URL(string: "rightyo") ?? relative, config: fake.config)
        }
        #expect(throws: RightyoChildError.unsafeExecutable) {
            try RightyoChildProcess.validate(executable: fake.directory, config: fake.config)
        }
        #expect(throws: RightyoChildError.unsafeConfig) {
            try RightyoChildProcess.validate(executable: fake.executable, config: fake.directory)
        }
        #expect(throws: RightyoChildError.unsafeConfig) {
            try RightyoChildProcess.validate(executable: fake.executable,
                                             config: fake.directory.appendingPathComponent("missing.json"))
        }
    }
}
#endif
