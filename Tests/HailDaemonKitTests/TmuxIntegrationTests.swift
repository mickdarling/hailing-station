import Foundation
import Testing
@testable import HailDaemonKit

/// True when `tmux -V` runs on this machine; the integration suite is skipped otherwise (#11, #29).
enum TmuxProbe {
    static let available: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "-V"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()
}

/// Against a real scratch tmux server on its own socket.
@Suite(.enabled(if: TmuxProbe.available), .serialized, .timeLimit(.minutes(1)))
struct TmuxIntegrationTests {

    @Test func quotesBackslashesSemicolonsAndAThousandCharactersArriveIntact() async throws {
        let socket = "hail-test-\(getpid())"
        let runner = ProcessCommandRunner()
        let fresh = TmuxAdapter(runner: runner, socket: socket, pollInterval: nil)
        #expect(try await fresh.listTargets().isEmpty, "a never-created socket lists nothing")
        let create = ["-L", socket, "new-session", "-d", "-s", "hail-test", "-x", "200", "-y", "50", "cat"]
        _ = try await runner.run("tmux", create)
        // The scratch server is killed on every exit path; a `defer` cannot await, so the failure is carried.
        var failure: (any Error)?
        do {
            try await exercise(TmuxAdapter(runner: runner, socket: socket, pollInterval: nil))
        } catch {
            failure = error
        }
        _ = try await runner.run("tmux", ["-L", socket, "kill-server"])
        try? FileManager.default.removeItem(atPath: "/tmp/tmux-\(getuid())/\(socket)")
        if let failure { throw failure }
    }

    private func exercise(_ adapter: TmuxAdapter) async throws {
        let tricky = #"he said "hi" \ back ; done"#
        let long = String(repeating: "0123456789", count: 100)
        try await adapter.deliver(tricky, to: "hail-test", binding: nil)
        try await adapter.deliver(long, to: "hail-test", binding: nil)
        try await Task.sleep(for: .milliseconds(400))
        let tail = try await adapter.capture("hail-test")

        let listed = try await adapter.listTargets()
        #expect(listed.map(\.name) == ["hail-test"])
        let binding = try #require(listed.first?.binding)
        #expect(binding.hasPrefix("$") && binding.contains("@") && binding.contains("/%"))
        try await adapter.deliver("bound", to: "hail-test", binding: binding)
        await #expect(throws: AdapterError.rebound("hail-test")) {
            try await adapter.deliver("x", to: "hail-test", binding: "$9@0")
        }
        #expect(tail.contains(tricky))
        #expect(tail.contains(long))
        await #expect(throws: AdapterError.unknownTarget("hail")) {
            try await adapter.deliver("x", to: "hail", binding: nil)
        }
    }
}
