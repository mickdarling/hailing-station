#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// Executable and config refusals; symlinks resolve to the path that is spawned (#203).
extension RightyoChildProcessTests {
    @Test func refusesUnsafeExecutablesAndConfigs() throws {
        for mode: mode_t in [0o775, 0o757, 0o644] {
            let fake = try FakeRightyo("exit 0", mode: mode)
            defer { fake.cleanUp() }
            #expect(throws: RightyoChildError.unsafeExecutable) { try fake.child() }
        }
        let owned = try FakeRightyo("exit 0", mode: 0o750)
        defer { owned.cleanUp() }
        #expect(throws: Never.self) {
            try RightyoChildProcess.validate(executable: owned.executable, config: owned.config)
        }
        #expect(chmod(owned.directory.path, 0o777) == 0)
        #expect(throws: RightyoChildError.unsafeExecutable) {
            try RightyoChildProcess.validate(executable: owned.executable, config: owned.config)
        }
        // A symlink is resolved; the resolved path is what gets spawned.
        let link = owned.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: FakeRightyo.shared)
        #expect(chmod(owned.directory.path, 0o700) == 0)
        #expect(try RightyoChildProcess.validate(executable: link, config: owned.config) == FakeRightyo.shared.path)
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

    @Test func refusesAWritableAncestorAboveTheParent() throws {
        let owned = try FakeRightyo("exit 0", mode: 0o750)
        defer { owned.cleanUp() }
        let nested = owned.directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let inner = nested.appendingPathComponent("rightyo")
        try FileManager.default.copyItem(at: owned.executable, to: inner)
        #expect(chmod(inner.path, 0o750) == 0)
        #expect(throws: Never.self) { try RightyoChildProcess.validate(executable: inner, config: owned.config) }
        for mode: mode_t in [0o770, 0o707] {
            #expect(chmod(owned.directory.path, mode) == 0)
            #expect(throws: RightyoChildError.unsafeExecutable) {
                try RightyoChildProcess.validate(executable: inner, config: owned.config)
            }
        }
        #expect(chmod(owned.directory.path, 0o700) == 0)
    }
}
#endif
