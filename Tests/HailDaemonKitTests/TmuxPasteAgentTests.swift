import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #608: a framed paste reaches a tmux pane only when the pane's foreground command is an agent, checked by the tmux
/// server in the same command as the paste. Against a real scratch tmux server: one pane runs `cat` under the name
/// `claude` (an agent by name), the other plain `cat` and `sh` (not agents). Synthetic text only.
@Suite(.enabled(if: TmuxProbe.available), .serialized, .timeLimit(.minutes(1)))
struct TmuxPasteAgentTests {
    @Test func theAgentFormatTestsEveryAgentCommand() {
        #expect(TmuxAdapter.isAgentFormat == "#{||:#{||:#{==:#{pane_current_command},claude},"
            + "#{==:#{pane_current_command},claude.exe}},#{==:#{pane_current_command},codex}}")
    }

    /// A pane that is not an agent: the device hears the plain reason as this request's refusal, not a dropped link.
    @Test func aNonAgentPaneRefusalReachesTheDeviceAsAPasteRefusal() async throws {
        let registry = Registry()
        try await registry.register(ShellPaneAdapter())
        var policy = Policy()
        try policy.allow("tmux:shell", binding: "binding-s", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame(capabilities: [RequestRefusals.capability]))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:shell"))))
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await session.receive(sessionFrame(
                target: "tmux:shell", payload: .text(TextPayload(text: "look", pasted: PastedText(text: "notes")))
            ))
        }
        #expect(try onlyControl(result) == .error(code: .pasteRefused, message: PastedContent.agentOnlyRefusal))
    }

    @Test func aPasteReachesAnAgentPaneAndNeverAShell() async throws {
        let socket = "hail-paste-\(getpid())"
        let runner = ProcessCommandRunner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // A tiny echo program built under the name `claude`, so tmux reports it as an agent (a copied system binary
        // is killed by the platform's code-signing rules).
        let agent = directory.appendingPathComponent("claude").path
        let source = directory.appendingPathComponent("echo.c")
        try "#include <unistd.h>\nint main(void){char b[4096];ssize_t n;while((n=read(0,b,sizeof b))>0)write(1,b,n);}\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let built = try await runner.run("/usr/bin/cc", ["-o", agent, source.path])
        try #require(built.exitCode == 0, "\(built.errorText)")
        let create = { (name: String, command: String) in
            ["-L", socket, "new-session", "-d", "-s", name, "-x", "200", "-y", "50", command]
        }
        _ = try await runner.run("tmux", create("agent", agent))
        _ = try await runner.run("tmux", create("plain", "cat"))
        _ = try await runner.run("tmux", create("shell", "/bin/sh"))
        var failure: (any Error)?
        do {
            try await exercise(TmuxAdapter(runner: runner, socket: socket, pollInterval: nil))
        } catch {
            failure = error
        }
        _ = try await runner.run("tmux", ["-L", socket, "kill-server"])
        try? FileManager.default.removeItem(atPath: "/tmp/tmux-\(getuid())/\(socket)")
        try? FileManager.default.removeItem(at: directory)
        if let failure { throw failure }
    }

    private func exercise(_ adapter: TmuxAdapter) async throws {
        try await Task.sleep(for: .milliseconds(300))
        let framed = try PastedContent.frame(spoken: "summarise this", pasted: "x'; touch PWNED #\nsecond line")
        for refused in ["plain", "shell"] {
            await #expect(throws: AdapterError.deliveryFailed(PastedContent.agentOnlyRefusal)) {
                try await adapter.deliver(framed, to: refused, binding: nil)
            }
            #expect(try await !adapter.capture(refused).contains(PastedContent.begin("")))
        }
        // The refusal pasted nothing, so the pane stays usable for spoken text.
        try await adapter.deliver("echo still-usable", to: "plain", binding: nil)
        try await adapter.deliver(framed, to: "agent", binding: nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await adapter.capture("agent").contains(PastedContent.begin("")))
        #expect(try await adapter.capture("plain").contains("still-usable"))
    }
}

/// A tmux target whose pane runs a shell: every framed paste is refused the way `TmuxAdapter.pasteToAgent` does.
private actor ShellPaneAdapter: Adapter {
    nonisolated let kind = "tmux"
    func listTargets() async throws -> [AdapterTarget] { [AdapterTarget(name: "shell", binding: "binding-s")] }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        if text.hasPrefix(PastedContent.begin("")) { throw AdapterError.deliveryFailed(PastedContent.agentOnlyRefusal) }
    }
    func capture(_ target: String) async throws -> String { "" }
}
