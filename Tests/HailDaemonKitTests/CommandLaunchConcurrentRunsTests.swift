#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

extension CommandLaunchAdmissionTests {
    @Test func oneRunnerLaunchesConcurrentCommandsBeforeEitherCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstMarker = directory.appendingPathComponent("first")
        let secondMarker = directory.appendingPathComponent("second")
        let release = directory.appendingPathComponent("release")
        let script = #"""
        : > "$1"
        while [ -d "$4" ] && [ ! -e "$2" ]; do sleep 0.01; done
        printf '%s\n' "$3"
        """#
        let runner = ProcessCommandRunner()
        let first = Task {
            try await runner.run("/bin/sh", ["-c", script, "sh", firstMarker.path,
                                             release.path, "first-output", directory.path])
        }
        let second = Task {
            try await runner.run("/bin/sh", ["-c", script, "sh", secondMarker.path,
                                             release.path, "second-output", directory.path])
        }
        do {
            let bothLaunched = try await bothMarkersAppear(firstMarker, secondMarker)
            #expect(!FileManager.default.fileExists(atPath: release.path))
            try #require(bothLaunched, "Both children must launch before either is released")
            try Data().write(to: release)
            let firstResult = try await first.value
            let secondResult = try await second.value
            #expect(firstResult.exitCode == 0)
            #expect(firstResult.stdout == "first-output\n")
            #expect(secondResult.exitCode == 0)
            #expect(secondResult.stdout == "second-output\n")
        } catch {
            // Removing the directory also releases children if writing the release file failed.
            try? FileManager.default.removeItem(at: directory)
            _ = await first.result
            _ = await second.result
            throw error
        }
    }

    private func bothMarkersAppear(_ first: URL, _ second: URL) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            let firstExists = FileManager.default.fileExists(atPath: first.path)
            let secondExists = FileManager.default.fileExists(atPath: second.path)
            if firstExists && secondExists { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
#endif
