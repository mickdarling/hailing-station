#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's voice routes in the device's target list (#636, slice 2): names and offline routes are shown, and
/// nothing about ids, policy or selection changes. Synthetic only: a fake tmux-kind adapter and an in-memory policy.
@Suite(.frozenGuardBudget, .timeLimit(.minutes(1))) struct VoiceRouteListingTests {
    static func routes() throws -> VoiceRoutes {
        try VoiceRoutes(defaultTarget: "tmux:scratch", routes: [
            .init(target: "tmux:scratch", name: "Hailing Scratch"), .init(target: "tmux:deck", name: "Deck"),
            .init(target: "tmux:voice", name: "Voice Work")
        ])
    }

    /// `scratch`, `deck` and `other` are running and allowed; `voice` is configured but not running, and `deck`
    /// is allowed at a binding it no longer has.
    func connected(routes: VoiceRoutes?) async throws -> HostSession {
        let adapter = FakeAdapter(kind: "tmux", targets: [
            AdapterTarget(name: "scratch", binding: "s1"), AdapterTarget(name: "deck", binding: "d2"),
            AdapterTarget(name: "other", binding: "o1")
        ])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:scratch", binding: "s1", tier: .open)
        try policy.allow("tmux:deck", binding: "d1", tier: .open)
        try policy.allow("tmux:other", binding: "o1", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer().naming(routes))
        _ = await session.receive(helloFrame())
        return session
    }

    func list(_ session: HostSession) async throws -> [TargetInfo] {
        let result = await session.receive(sessionFrame(payload: .control(.listTargets)))
        guard case .targets(let targets) = try onlyControl(result) else { throw TestSupportError.expectedOneControl }
        return targets
    }

    @Test func routesShowTheirNamesAndUnavailableRoutesShowOffline() async throws {
        let targets = try await list(try await connected(routes: try Self.routes()))
        #expect(targets == [
            TargetInfo(id: "tmux:deck", kind: "tmux", name: "Deck", alive: false),
            TargetInfo(id: "tmux:other", kind: "tmux", name: "other", alive: true),
            TargetInfo(id: "tmux:scratch", kind: "tmux", name: "Hailing Scratch", alive: true),
            TargetInfo(id: "tmux:voice", kind: "tmux", name: "Voice Work", alive: false)
        ])
    }

    @Test func withoutRoutesTheListIsUnchanged() async throws {
        let targets = try await list(try await connected(routes: nil))
        #expect(targets.map(\.id) == ["tmux:other", "tmux:scratch"] && targets.map(\.name) == ["other", "scratch"])
    }

    /// An offline route is shown, never selectable: the name file grants nothing the policy does not.
    @Test func anOfflineRouteCannotBeSelectedAndANamedOneCan() async throws {
        let session = try await connected(routes: try Self.routes())
        for offline in ["tmux:voice", "tmux:deck"] {
            let refused = await session.receive(sessionFrame(payload: .control(.select(targetID: offline))))
            guard case .error(let code, _) = try onlyControl(refused) else { throw TestSupportError.expectedOneControl }
            #expect(code == .notAllowed)
            #expect(await session.selectedTarget == nil)
        }
        let selected = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:scratch"))))
        #expect(selected.frames.isEmpty)
        #expect(await session.selectedTarget == "tmux:scratch")
    }
}

/// `--voice-routes` (#636): an absolute path, once, only on the personal terminal; a missing file leaves routing off
/// and a file that does not load refuses startup.
@Suite(.serialized, .frozenGuardBudget, .timeLimit(.minutes(1))) struct VoiceRouteOptionsTests {
    static let base = ["--bind", "127.0.0.1", "--port", "4100"]

    @Test func theFlagNeedsThePersonalTerminalAndAnAbsolutePathOnce() throws {
        let file = ["--voice-routes", "/tmp/routes.json"]
        #expect(try ConnectionProbeDaemon.options(Self.base + ["--personal-terminal"] + file).voiceRoutes?.path
            == "/tmp/routes.json")
        #expect(try ConnectionProbeDaemon.options(Self.base + ["--personal-terminal"]).voiceRoutes == nil)
        for arguments in [["--connection-probe"] + file, ["--personal-terminal", "--voice-routes", "routes.json"],
                          ["--personal-terminal", "--voice-routes"], ["--personal-terminal"] + file + file] {
            #expect(throws: WebSocketListenerError.invalidArguments) {
                try ConnectionProbeDaemon.options(Self.base + arguments)
            }
        }
    }

    @Test func aMissingFileIsOffAndABadFileRefusesStartup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("routes.json")
        let events = Mutex<[String]>([])
        let log: @Sendable (WebSocketListenerEvent) -> Void = { event in
            events.withLock { $0.append("\(event.event) \(event.detail ?? "")") }
        }
        #expect(try ConnectionProbeDaemon.voiceRoutes(file, log: log) == nil)
        try Data(#"{"version": 1, "default": "tmux:a", "routes": [{"target": "tmux:a", "name": "A"}]}"#.utf8)
            .write(to: file)
        #expect(try ConnectionProbeDaemon.voiceRoutes(file, log: log)?.defaultTarget == "tmux:a")
        try Data("not json".utf8).write(to: file)
        #expect(throws: VoiceRoutes.LoadError.malformed) { try ConnectionProbeDaemon.voiceRoutes(file, log: log) }
        #expect(events.withLock { $0 } == ["voice_routes missing", "voice_routes count=1",
                                           "voice_routes error=malformed"])
    }
}
#endif
