#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Exercise the daemon parser and router with a synthetic local child. A rename acknowledges that
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
        let attempts = Mutex(0)
        private let sink = DispatchQueue(label: "synthetic.self-voice.log")
        private let firstLog = Mutex(true)
        let fallbacks = AsyncStream<WebSocketListenerEvent>.makeStream()
        let ended = AsyncStream<Void>.makeStream()

        func record(_ event: WebSocketListenerEvent, blocking gate: RecipientPublicationGate?) {
            guard let gate else { return record(event) }
            // Model a single blocked sink: all later writes queue behind the first fallback line.
            sink.sync {
                if event.event == "self-voice", firstLog.withLock({ first in
                    defer { first = false }
                    return first
                }) { _ = gate.block(onDedicatedQueue: true) }
                record(event)
            }
        }

        func record(_ event: WebSocketListenerEvent) {
            if event.event == "self-voice" { fallbacks.continuation.yield(event) }
            if event.event == "ambient_ended" { ended.continuation.yield(()) }
        }
    }

    struct Hooks: Sendable {
        var logGate: RecipientPublicationGate?
        var read: SelfVoiceSpawnVerification.Read = SelfVoicePrivateFile.boundedBytes
    }

    private init(enabled: Bool, crash: Bool, renderer: any SelfVoiceEnrollmentRendering,
                 hooks: Hooks) async throws {
        files = try EnrollmentFixture()
        let capture = #"printf '%s\0' "$@" > argv.tmp && /bin/mv argv.tmp argv"#
        let recordAudio = #"/bin/cat > "$7.tmp" && /bin/mv "$7.tmp" "$7.pcm""#
        fake = try FakeRightyo(capture + "\n" + (crash ? "exit 17" : recordAudio))
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
                let publisher = SelfVoicePublisher(directory: directory, clock: { 100 })
                let verification = SelfVoiceSpawnVerification(read: hooks.read)
                return SelfVoiceLaunchPreparation(enrollmentPath: path, publisher: publisher, clock: clock.clock,
                                                  timeout: .seconds(20), spawnVerification: verification) { _ in
                    events.attempts.withLock { $0 += 1 }
                    return renderer
                }
            }, log: { [events] in events.record($0, blocking: hooks.logGate) }
        )
        listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host, ambient: router)
    }

    static func withRig(
        enabled: Bool = true, crash: Bool = false, renderer: any SelfVoiceEnrollmentRendering = SyntheticSelfVoice(),
        hooks: Hooks = .init(), _ body: (AmbientSelfVoiceSwitchRig) async throws -> Void
    ) async throws {
        let rig = try await Self(enabled: enabled, crash: crash, renderer: renderer, hooks: hooks)
        defer { rig.fake.cleanUp(); rig.files.remove() }
        do {
            try await body(rig)
        } catch {
            await rig.shutDown()
            throw error
        }
        await rig.shutDown()
    }

    private func shutDown() async {
        let flight = router.backgroundSelfVoice?.inFlight
        await router.shutdown()
        await flight?.value
    }

    @discardableResult func start(on owner: UUID? = nil) -> UUID {
        let stream = UUID()
        router.ambientAudio(.started(stream: stream, connection: owner ?? connection, scope: scope))
        return stream
    }

    func waitForExit() async throws {
        var ended = events.ended.stream.makeAsyncIterator()
        _ = try #require(await ended.next())
    }

    func expectReason(_ reason: BackgroundSelfVoice.Reason) async throws {
        var iterator = events.fallbacks.stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event == WebSocketListenerEvent(event: "self-voice", detail: "off for this child (\(reason.rawValue))"))
    }

    var constructions: Int { events.built.withLock { $0 } }
    var attempts: Int { events.attempts.withLock { $0 } }

    func recordedAudio(_ session: String) async throws -> Data {
        let file = fake.directory.appendingPathComponent(session + ".pcm")
        try await watch.wait(for: file)
        return try Data(contentsOf: file)
    }

    func socketReload() async throws -> LocalReplyResponse {
        // Keep the physical path short enough for sockaddr_un on macOS.
        let scratch = files.root.deletingLastPathComponent().appendingPathComponent("sv-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: listener,
                                              audit: AuditLog(directory: scratch.appendingPathComponent("audit")))
        try await endpoint.start()
        do {
            let response = try await submit(Data(#"{"kind":"ambient","action":"reload"}"#.utf8), socket: socket.path)
            await endpoint.stop()
            return response
        } catch {
            await endpoint.stop()
            throw error
        }
    }

    @discardableResult func expectArgv(manifest: Bool, startPrivate: Bool = false) async throws -> String {
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
        let expected = ordinary + (startPrivate ? ["--start-private"] : [])
            + (manifest ? ["--self-voice-manifest", files.manifest.path] : [])
        #expect(bytes == Data((expected.joined(separator: "\0") + "\0").utf8))
        return session
    }
}

extension HeldSelfVoiceRender {
    func waitUntilStarted() async throws {
        var iterator = started.stream.makeAsyncIterator()
        _ = try #require(await iterator.next())
    }
}
#endif
