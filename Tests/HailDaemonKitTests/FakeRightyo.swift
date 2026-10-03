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
#endif
