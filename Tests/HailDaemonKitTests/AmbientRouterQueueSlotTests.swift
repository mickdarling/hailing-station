#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(2))) struct AmbientRouterQueueSlotTests {
    @Test func reloadSlot() async throws {
        let capture = #"printf '%s\0' "$@" > argv.tmp && /bin/mv argv.tmp argv"#
        let recordAudio = #"/bin/cat > "$7.tmp" && /bin/mv "$7.tmp" "$7.pcm""#
        let fake = try FakeRightyo(capture + "\n" + recordAudio)
        defer { fake.cleanUp() }
        let host = try await RecipientTestRig.make().host, target = RecipientTestRig.target
        let scope = AmbientStreamScope(target: target, selection: nil, binding: "reply-binding",
                                       policyGeneration: host.targetPolicy.snapshot(for: target))
        let arguments = AmbientWiringOptionsTests.base + AmbientWiringOptionsTests.personal
            + ["--ambient-rightyo", fake.executable.path, "--ambient-rightyo-config", fake.config.path,
               "--ambient-target", target]
        let options = try #require(try ConnectionProbeDaemon.options(arguments).ambient)
        let router = try await ConnectionProbeDaemon.ambientRouter(options, host: host, log: { _ in })
        // Attaches the router's listener, as the daemon does (pre-arm refuses `stopping` without one).
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host, ambient: router)
        defer { withExtendedLifetime(listener) {} }
        let connection = UUID()

        // No peer socket: hold the device notice so a no-connection response cannot disarm the pre-arm.
        let notices = AsyncStream<Void>.makeStream()
        router.mediaNotices.enqueue { for await _ in notices.stream { break } }
        defer { notices.continuation.finish() }
        router.ambientPrivacyPreArm(connection: connection)
        try #require(router.duckMode(connection: connection))

        // The reload slot is occupied, as `reload()` holds it while it builds a child: events queue, no child yet.
        router.state.withLock { $0.reloading = true }
        defer { router.state.withLock { $0.reloading = false } }
        let stream = UUID()
        router.ambientAudio(.started(stream: stream, connection: connection, scope: scope))
        let privateBytes = Data(repeating: 0x71, count: 32), publicBytes = Data(repeating: 0x42, count: 32)
        for sequence in 0..<3 {
            router.ambientAudio(.segment(stream: stream, sequence: sequence, bytes: privateBytes))
        }
        try #require(router.state.withLock { $0.queue.count == 4 && $0.runs.isEmpty })
        _ = router.setDuck(false, connection: connection, reason: "device")
        try #require(!router.duckMode(connection: connection))
        router.state.withLock { $0.reloading = false }
        try #require(await eventually { router.activeStream == stream }, "probe child started")
        router.ambientAudio(.segment(stream: stream, sequence: 3, bytes: publicBytes))

        let session = try await launchedSession(fake)
        router.ambientAudio(.ended(stream: stream, reason: .final))
        let pcm = fake.directory.appendingPathComponent(session + ".pcm")
        try #require(await eventually { FileManager.default.fileExists(atPath: pcm.path) }, "probe audio recorded")
        #expect(try Data(contentsOf: pcm) == publicBytes)
        await router.shutdown()
    }

    private func launchedSession(_ fake: FakeRightyo) async throws -> String {
        let argvFile = fake.directory.appendingPathComponent("argv")
        try #require(await eventually { FileManager.default.fileExists(atPath: argvFile.path) })
        let fields = try Data(contentsOf: argvFile).split(separator: 0)
        let argv = try fields.map { try #require(String(data: $0, encoding: .utf8)) }
        #expect(!argv.contains("--start-private"))
        return try #require(argv.count >= 7 ? argv[6] : nil)
    }
}
#endif
