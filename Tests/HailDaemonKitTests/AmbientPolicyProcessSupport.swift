import Darwin
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// The real CLI writes a private scratch policy; its tmux listing contains synthetic bindings only.
struct AmbientPolicyProcessRig {
    let directory: URL
    let file: PolicyFile
    let host: HailHost
    let session: HostSession
    let gate: AmbientAudioGate
    let sink: RecordingAmbientSink
    let adapter: FakeAdapter
    let stream = UUID()

    static func make(startStream: Bool = true, reload: PolicyReloadStore.Hook? = nil) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-stat-\(UUID())")
        let file = PolicyFile(directory: directory)
        do {
            var policy = Policy()
            try policy.allow("tmux:a", binding: "$1@1/%1:1", tier: .open)
            try policy.allow("tmux:b", binding: "$2@1/%2:2", tier: .open)
            try file.save(policy)
            let tmux = directory.appendingPathComponent("tmux")
            let script = "#!/bin/sh\nprintf '%s\\n' '$1|1|%1|1|a' '$2|1|%2|2|b'\n"
            try Data(script.utf8).write(to: tmux)
            try #require(chmod(tmux.path, 0o700) == 0)
            let adapter = FakeAdapter(kind: "tmux", targets: [
                AdapterTarget(name: "a", binding: "$1@1/%1:1"),
                AdapterTarget(name: "b", binding: "$2@1/%2:2")
            ])
            let registry = Registry()
            try await registry.register(adapter)
            let store: any PolicyStore = reload.map { PolicyReloadStore(file: file, hook: $0) } ?? file
            let host = try HailHost(registry: registry, store: store)
            let sink = RecordingAmbientSink()
            let gate = ambientGate(sink: sink, clock: AmbientTestClock())
            let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
            _ = await session.receive(helloFrame())
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
            let rig = Self(directory: directory, file: file, host: host, session: session, gate: gate, sink: sink,
                           adapter: adapter)
            if startStream {
                let start: HostSessionResult = await rig.segment(0)
                try #require(start.frames.isEmpty)
                try #require(sink.segments == [0])
            }
            return rig
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func segment(_ sequence: Int) async -> HostSessionResult {
        await session.receive(sessionFrame(target: "tmux:a", payload: .audio(
            ambientSegment(stream: stream, sequence: sequence)
        )))
    }

    func input() async throws -> AuthorizedInput {
        let frame: Frame = sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: "synthetic")))
        return try await authorizedInput(session, frame, device: "test")
    }

    func write(_ operation: String, target: String = "tmux:a", tier: String? = nil) async throws {
        try await withTaskExecutorPreference(HeavyTestExecutor.shared) {
            try runCLI(operation, target: target, tier: tier)
        }
    }

    func removePolicy() async throws {
        try await withTaskExecutorPreference(HeavyTestExecutor.shared) {
            try runProcess(URL(fileURLWithPath: "/bin/rm"), arguments: [file.path.path])
        }
    }

    func mutateDirectory(_ mutation: String) async throws {
        let script: String
        switch mutation {
        case "permissions": script = "chmod 750 \"$1\""
        case "symlink": script = "mv \"$1\" \"$2\" && ln -s \"$2\" \"$1\""
        default:
            script = "mv \"$1\" \"$2\" && mkdir -m 700 \"$1\" && ln \"$2/policy.json\" \"$1/policy.json\""
        }
        try await withTaskExecutorPreference(HeavyTestExecutor.shared) {
            try runProcess(URL(fileURLWithPath: "/bin/sh"),
                           arguments: ["-c", script, "synthetic", directory.path, directory.path + ".moved"])
        }
    }

    private func runCLI(_ operation: String, target: String, tier: String?) throws {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/haild")
        var arguments = ["targets", operation, target]
        if let tier { arguments += operation == "allow" ? ["--tier", tier] : [tier] }
        try runProcess(executable, arguments: arguments)
    }

    private func runProcess(_ executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HAIL_CONFIG_DIR": directory.path,
                               "HAIL_TMUX": directory.appendingPathComponent("tmux").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let finished: Bool = exited.wait(timeout: .now() + .seconds(10)) == .success
        if !finished {
            kill(process.processIdentifier, SIGKILL)
            let killed: Bool = exited.wait(timeout: .now() + .seconds(5)) == .success
            try #require(killed, "The killed policy process did not terminate within its cleanup bound")
        }
        // Foundation reaps before its termination handler signals; both waits use this dedicated queue (#1023).
        try #require(finished, "The policy process timed out")
        try #require(process.terminationStatus == 0, "The policy process failed")
    }
}
