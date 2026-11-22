#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Exercise the daemon parser and router without opening a listening socket. A rename acknowledges that
/// the fake child has recorded every argv byte. Its exit or EOF is independent of the preparation clock.
final class AmbientSelfVoiceSwitchRig: Sendable {
    let files: EnrollmentFixture
    let fake: FakeRightyo
    let clock = ProgressTestClock()
    let connection = UUID()
    let router: AmbientRightyoRouter
    let listener: WebSocketListener
    let scope: AmbientStreamScope
    private let watch: TaskProgressPeerFileWatch
    private let events = Observations()

    private final class Observations: Sendable {
        let built = Mutex(0)
        let failures = Mutex<[WebSocketListenerEvent]>([])
        let ended = AsyncStream<Void>.makeStream()

        func record(_ event: WebSocketListenerEvent) {
            if event.event == "self-voice" { failures.withLock { $0.append(event) } }
            if event.event == "ambient_ended" { ended.continuation.yield(()) }
        }
    }

    private init(enabled: Bool, crash: Bool, renderer: any SelfVoiceEnrollmentRendering) async throws {
        files = try EnrollmentFixture()
        let capture = #"printf '%s\0' "$@" > argv.tmp && /bin/mv argv.tmp argv"#
        fake = try FakeRightyo(capture + (crash ? "\nexit 17" : "\nexec /bin/cat >/dev/null"))
        watch = try TaskProgressPeerFileWatch(fake.directory)
        let rig = try await RecipientTestRig.make(), target = RecipientTestRig.target
        scope = AmbientStreamScope(target: target, selection: nil, binding: "reply-binding",
                                   policyGeneration: rig.host.targetPolicy.snapshot(for: target))
        let arguments = AmbientWiringOptionsTests.base + AmbientWiringOptionsTests.personal
            + ["--ambient-rightyo", fake.executable.path, "--ambient-rightyo-config", fake.config.path,
               "--ambient-target", target] + (enabled ? ["--ambient-self-voice", files.file.path] : [])
        let options = try #require(try ConnectionProbeDaemon.options(arguments).ambient)
        router = try await ConnectionProbeDaemon.ambientRouter(
            options, host: rig.host, selfVoiceDirectory: files.directory,
            makePreparation: { [files, clock, events] path, directory in
                events.built.withLock { $0 += 1 }
                #expect(path == files.file.path && directory == files.directory.path)
                return SelfVoiceLaunchPreparation(enrollmentPath: path, directory: directory,
                                                  clock: clock.clock, renderer: { _ in renderer })
            }, log: events.record
        )
        listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host, ambient: router)
    }

    static func withRig(
        enabled: Bool = true, crash: Bool = false, renderer: any SelfVoiceEnrollmentRendering = SyntheticSelfVoice(),
        _ body: (AmbientSelfVoiceSwitchRig) async throws -> Void
    ) async throws {
        let rig = try await Self(enabled: enabled, crash: crash, renderer: renderer)
        defer { rig.fake.cleanUp(); rig.files.remove() }
        do {
            try await body(rig)
        } catch {
            await rig.router.shutdown()
            throw error
        }
        await rig.router.shutdown()
    }

    func start() {
        router.ambientAudio(.started(stream: UUID(), connection: connection, scope: scope))
    }

    func waitForCrash() async throws {
        var ended = events.ended.stream.makeAsyncIterator()
        _ = try #require(await ended.next())
    }

    /// Registration can emit ambient_started just before the ordered worker relinquishes the launch slot.
    func waitForLaunchSlot() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while router.state.withLock({ $0.working || !$0.queue.isEmpty }) {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
    }

    var constructions: Int { events.built.withLock { $0 } }
    var failures: [WebSocketListenerEvent] { events.failures.withLock { $0 } }

    func expectArgv(manifest: Bool) async throws {
        let file = fake.directory.appendingPathComponent("argv")
        try await watch.wait(for: file)
        let bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        let arguments: [Data] = bytes.split(separator: 0)
        try #require(arguments.count >= 7)
        let session = try #require(String(bytes: arguments[6], encoding: .utf8))
        #expect(session.hasPrefix("hail-") && UUID(uuidString: String(session.dropFirst(5))) != nil)
        let ordinary = ["listen", "--mode", "stdin", "--provenance", "live-microphone",
                        "--session-id", session, "--config", fake.config.path]
        let expected = ordinary + (manifest ? ["--self-voice-manifest", files.manifest.path] : [])
        #expect(bytes == Data((expected.joined(separator: "\0") + "\0").utf8))
    }
}
#endif
