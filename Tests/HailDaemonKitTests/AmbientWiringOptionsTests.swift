import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// `haild run` ambient flags (#203): all three or none, and only on the personal terminal with the
/// single-terminal reply fallback.
@Suite struct AmbientWiringOptionsTests {
    static let base = ["--bind", "127.0.0.1", "--port", "4100"]
    static let personal = ["--personal-terminal", "--single-terminal-reply-fallback"]
    static let ambient = ["--ambient-rightyo", "/opt/rightyo/bin/rightyo", "--ambient-rightyo-config",
                          "/opt/rightyo/config.json", "--ambient-target", "tmux:a"]

    @Test func noAmbientFlagsLeaveAmbientOff() throws {
        #expect(try ConnectionProbeDaemon.options(Self.base + Self.personal).ambient == nil)
        #expect(try ConnectionProbeDaemon.options(Self.base + ["--connection-probe"]).ambient == nil)
        #expect(try ConnectionProbeDaemon.options(Self.base + Self.personal).authorizer.ambientAudio == nil)
    }

    @Test func allThreeFlagsWithBothPrerequisitesParse() throws {
        let options = try ConnectionProbeDaemon.options(Self.base + Self.personal + Self.ambient)
        #expect(options.ambient == .init(executable: URL(fileURLWithPath: "/opt/rightyo/bin/rightyo"),
                                         config: URL(fileURLWithPath: "/opt/rightyo/config.json"), target: "tmux:a"))
        #expect(options.singleTerminalReplyFallback)
        #expect(options.ambient?.ackClips == nil)
    }

    @Test func theAckClipFolderRidesWithTheAmbientFlags() throws {
        let options = try ConnectionProbeDaemon.options(
            Self.base + Self.personal + Self.ambient + ["--ambient-ack-clips", "/Users/me/.config/hail/ack-clips"]
        )
        #expect(options.ambient?.ackClips == URL(fileURLWithPath: "/Users/me/.config/hail/ack-clips"))
    }

    static let refused: [[String]] = {
        let head = base + personal
        let (exe, config, target) = (Array(ambient.prefix(2)), Array(ambient[2..<4]), Array(ambient.suffix(2)))
        var refused: [[String]] = []
        // Missing prerequisites.
        refused.append(base + ["--personal-terminal"] + ambient)
        refused.append(base + ["--connection-probe"] + ambient)
        refused.append(base + ["--connection-probe", "--single-terminal-reply-fallback"] + ambient)
        // Incomplete sets.
        refused.append(head + exe + config)
        refused.append(head + config + target)
        refused.append(head + target)
        // Bad values: relative paths, a target that is another option, missing or empty.
        refused.append(head + ["--ambient-rightyo", "rightyo"] + config + target)
        refused.append(head + exe + ["--ambient-rightyo-config", "config.json"] + target)
        refused.append(head + exe + config + ["--ambient-target", "--port"])
        refused.append(head + exe + config + ["--ambient-target"])
        refused.append(head + exe + config + ["--ambient-target", ""])
        // Duplicates.
        refused.append(head + ambient + ["--ambient-target", "tmux:b"])
        // Acknowledgement clips (rightyo#105): only with the ambient set, an absolute path, once.
        refused.append(head + ["--ambient-ack-clips", "/clips"])
        refused.append(head + ambient + ["--ambient-ack-clips", "clips"])
        refused.append(head + ambient + ["--ambient-ack-clips"])
        refused.append(head + ambient + ["--ambient-ack-clips", "/a", "--ambient-ack-clips", "/b"])
        return refused
    }()

    @Test(arguments: refused)
    func refusedCombinations(_ arguments: [String]) {
        #expect(throws: WebSocketListenerError.invalidArguments) { try ConnectionProbeDaemon.options(arguments) }
    }
}

#if os(macOS)
@Suite(.timeLimit(.minutes(1))) struct AmbientStartupValidationTests {
    @Test func startupPinsTheListedBindingAndRefusesUnknownTargetsAndUnsafeExecutables() async throws {
        let rig = try await RecipientTestRig.make()
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        let options = ConnectionProbeDaemon.AmbientOptions(
            executable: fake.executable, config: fake.config, target: RecipientTestRig.target
        )
        let router = try await ConnectionProbeDaemon.ambientRouter(options, host: rig.host, log: { _ in })
        #expect(router.configuration.binding == "reply-binding")
        #expect(!router.configuration.allowSynthetic)
        var unknown = options
        unknown.target = "recipient:missing"
        await #expect(throws: HostError.unknownTarget("recipient:missing")) {
            try await ConnectionProbeDaemon.ambientRouter(unknown, host: rig.host, log: { _ in })
        }
        let writable = try FakeRightyo("exit 0", mode: 0o775)
        defer { writable.cleanUp() }
        var unsafe = options
        unsafe.executable = writable.executable
        await #expect(throws: RightyoChildError.unsafeExecutable) {
            try await ConnectionProbeDaemon.ambientRouter(unsafe, host: rig.host, log: { _ in })
        }
        // The reply block quotes the target, so an unsafe id refuses startup instead of every stream.
        var quoted = options
        quoted.target = "recipient:reply; rm"
        await #expect(throws: RightyoTargetError.unsafeIdentifier) {
            try await ConnectionProbeDaemon.ambientRouter(quoted, host: rig.host, log: { _ in })
        }
    }

    /// Clips load once at startup (rightyo#105); missing or empty clips turn acknowledgements off, never startup.
    @Test func ackClipsLoadAtStartupAndMissingOnesLeaveAcknowledgementsOff() async throws {
        let rig = try await RecipientTestRig.make()
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hs-ackcfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let jarvis = root.appendingPathComponent("jarvis")
        try FileManager.default.createDirectory(at: jarvis, withIntermediateDirectories: true)
        try AmbientAcknowledgementTests.wav(samples: 10).write(to: jarvis.appendingPathComponent("a.wav"))
        var options = ConnectionProbeDaemon.AmbientOptions(
            executable: fake.executable, config: fake.config, target: RecipientTestRig.target, ackClips: root
        )
        let logged = Mutex<[String]>([])
        let log: @Sendable (WebSocketListenerEvent) -> Void = { event in
            if event.event == "ambient_ack_clips" { logged.withLock { $0.append(event.detail ?? "") } }
        }
        let loaded = try await ConnectionProbeDaemon.ambientRouter(options, host: rig.host, log: log)
        #expect(loaded.configuration.acknowledgements?.clips.keys.sorted() == ["jarvis"])
        options.ackClips = root.appendingPathComponent("missing")
        let missing = try await ConnectionProbeDaemon.ambientRouter(options, host: rig.host, log: log)
        #expect(missing.configuration.acknowledgements == nil)
        #expect(logged.withLock { $0 } == ["personas=1 clips=1", "personas=0 clips=0"])
    }
}
#endif
