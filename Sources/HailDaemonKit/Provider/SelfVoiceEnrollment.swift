#if os(macOS)
import Darwin
import Foundation
import HailProtocol
import Synchronization

struct SelfVoiceEnrollment: Sendable {
    enum Failure: Error, Equatable { case file, size, schema, version, executable, voice, ids }

    let file: URL, executable: URL
    let voices: [SelfVoiceConfiguration]

    static func load(_ path: String) throws -> Self {
        let data: Data
        do {
            let parent = try SelfVoicePrivateFile.openParent(path)
            defer { close(parent.descriptor) }
            guard !path.hasSuffix("/"),
                  let contents = try SelfVoicePrivateFile.read(parent.leaf, in: parent.descriptor,
                                                               limit: SelfVoiceManifest.limit)
            else { throw Failure.file }
            data = contents.0
        } catch SelfVoiceError.manifest { throw Failure.size } catch { throw Failure.file }
        // Use the bounded JSON reader so duplicate object keys cannot disappear during decoding.
        guard case let .object(object)? = try? CodexJSONL.decode(data),
              Set(object.keys) == ["version", "vbsay", "voices"],
              case let .string(wrapper) = object["vbsay"], case let .array(entries) = object["voices"]
        else { throw Failure.schema }
        guard object["version"] == .integer(1) else { throw Failure.version }
        let file = URL(fileURLWithPath: path, isDirectory: false)
        let executable = try validatedExecutable(wrapper, config: file)
        let voices = try entries.map(voice)
        do { try SelfVoiceManifest.checkIDs(voices.map(\.id)) } catch { throw Failure.ids }
        return Self(file: file, executable: executable, voices: voices)
    }

    static func validatedExecutable(_ path: String, config: URL) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw Failure.executable }
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard let real = try? RightyoChildProcess.validate(executable: url, config: config),
              real.utf8.elementsEqual(path.utf8) else { throw Failure.executable }
        return url
    }

    private static func voice(_ value: JSONValue) throws -> SelfVoiceConfiguration {
        guard case let .object(fields) = value,
              Set(fields.keys) == ["id", "profile", "source", "revision", "endpoint"],
              case let .string(id) = fields["id"], case let .string(profile) = fields["profile"],
              case let .string(sourceName) = fields["source"], case let .string(revision) = fields["revision"],
              case let .string(endpoint) = fields["endpoint"] else { throw Failure.schema }
        guard let source = SelfVoiceConfiguration.Source(rawValue: sourceName) else { throw Failure.voice }
        let config = SelfVoiceConfiguration(id: id, profile: profile, source: source,
                                            revision: revision, endpoint: endpoint)
        guard (try? config.origin())?.host == "127.0.0.1" else { throw Failure.voice }
        return config
    }
}

private struct VerifiedEnrollment: Sendable {
    let enrollment: SelfVoiceEnrollment
    let manifest: SelfVoiceManifest

    func entry(for voice: SelfVoiceConfiguration, executable: URL) -> SelfVoiceManifest.Voice? {
        guard enrollment.executable.path.utf8.elementsEqual(executable.path.utf8),
              let index = enrollment.voices.firstIndex(of: voice) else { return nil }
        return manifest.voices[index]
    }
}

private enum EnrollmentWave: Sendable {
    case verified(SelfVoiceManifest.Voice)
    case rendered(SelfVoiceConfiguration, Data)
}

private extension SelfVoicePublisher {
    /// Rendering holds no directory lock. A timed-out renderer cannot hold up the next spawn's fresh attempt.
    func prepare(_ enrollment: SelfVoiceEnrollment, previous: VerifiedEnrollment?, renderer: any SelfVoiceRendering,
                 check: @Sendable () throws -> Void) async throws -> VerifiedEnrollment {
        let waves = try await render(enrollment, previous: previous, renderer: renderer, check: check)
        try check()
        let directory = try SelfVoiceDirectory(path)
        do {
            let old = try directory.previous()
            var timestamp = old.timestamp
            let voices = try waves.map { wave -> SelfVoiceManifest.Voice in
                try check()
                switch wave {
                case .verified(let entry):
                    guard old.manifest?.voices.contains(entry) == true else { throw SelfVoiceError.manifest }
                    return entry
                case let .rendered(config, wav):
                    guard timestamp < Int.max else { throw SelfVoiceError.manifest }
                    timestamp = max(clock(), timestamp + 1)
                    let name = "self-\(UUID().uuidString).wav"
                    try directory.install(wav, as: name, check: check)
                    return .init(id: config.id, file: name, source: config.source, renderedAt: timestamp,
                                 sha256: SelfVoiceWave.digest(wav))
                }
            }
            let manifest = SelfVoiceManifest(version: 1, voices: voices)
            try directory.finishLaunch(manifest, previous: previous?.manifest, old: old.manifest,
                                       timestamp: timestamp, check: check)
            return VerifiedEnrollment(enrollment: enrollment, manifest: manifest)
        } catch {
            directory.rollbackAfterFailure()
            throw error
        }
    }

    private func render(_ enrollment: SelfVoiceEnrollment, previous: VerifiedEnrollment?,
                        renderer: any SelfVoiceRendering, check: @Sendable () throws -> Void) async throws
        -> [EnrollmentWave] {
        var waves: [EnrollmentWave] = []
        for voice in enrollment.voices {
            try check()
            do {
                _ = try await renderer.profileID(named: voice.profile, at: voice.origin())
                try check()
                if let entry = previous?.entry(for: voice, executable: enrollment.executable) {
                    waves.append(.verified(entry))
                } else {
                    let pcm = try await renderer.pcm(for: voice)
                    try check()
                    waves.append(.rendered(voice, try SelfVoiceWave.encode(pcm)))
                }
            } catch let refusal as SelfVoiceEnrollment.Failure {
                throw refusal
            } catch { throw SelfVoiceLaunchPreparation.Failure.render }
        }
        return waves
    }
}

private extension SelfVoiceDirectory {
    func finishLaunch(_ manifest: SelfVoiceManifest, previous: SelfVoiceManifest?, old: SelfVoiceManifest?,
                      timestamp: Int, check: () throws -> Void) throws {
        if previous == manifest, old == manifest {
            try verifyWaves(manifest)
        } else {
            try commit(manifest, timestamp: timestamp, check: check)
            let retained = Set((manifest.voices + (old?.voices ?? [])).map(\.file))
            try removeSuperseded(keeping: retained)
        }
        try verifyManifest(manifest)
        try check()
    }
}

private final class PreparationDeadline: Sendable {
    let end: ContinuousClock.Instant
    private let clock: TaskProgressClock
    private let revoked = Mutex(false)

    init(clock: TaskProgressClock, timeout: Duration) {
        self.clock = clock
        end = clock.now() + timeout
    }

    func revoke() { revoked.withLock { $0 = true } }

    func check() throws {
        guard clock.now() < end else { throw SelfVoiceLaunchPreparation.Failure.timeout }
        guard !revoked.withLock({ $0 }) else { throw SelfVoiceLaunchPreparation.Failure.cancelled }
        try Task.checkCancellation()
    }
}

/// One instance per opted-in daemon. Call before each child spawn, never on an audio callback.
/// A disabled daemon omits this object entirely.
actor SelfVoiceLaunchPreparation {
    enum Failure: String, Error { case read, validation, render, publication, timeout, cancelled }
    typealias Renderer = @Sendable (SelfVoiceEnrollment) -> any SelfVoiceRendering

    private let enrollmentPath: String, manifestURL: URL
    private let publisher: SelfVoicePublisher
    private let clock: TaskProgressClock, timeout: Duration, renderer: Renderer
    private var verified: VerifiedEnrollment?
    private struct Attempt {
        let id: UUID, deadline: PreparationDeadline
        let worker: Task<Void, Never>, timer: Task<Void, Never>
        let waiter: CheckedContinuation<URL?, Never>
    }
    private var active: Attempt?
    /// Retirement observation for synthetic tests. A launch never joins this handle.
    var inFlightWork: Task<Void, Never>? { active?.worker }
    private(set) var lastFailure: Failure?

    init(enrollmentPath: String, directory: String) {
        self.init(enrollmentPath: enrollmentPath, publisher: SelfVoicePublisher(directory: directory),
                  clock: .continuous, timeout: .seconds(20), renderer: { EnrolledReplyRenderer(enrollment: $0) })
    }

    init(enrollmentPath: String, publisher: SelfVoicePublisher, clock: TaskProgressClock,
         timeout: Duration, renderer: @escaping Renderer) {
        self.enrollmentPath = enrollmentPath
        self.publisher = publisher
        let directory = URL(fileURLWithPath: publisher.path, isDirectory: true)
        manifestURL = directory.appendingPathComponent(SelfVoiceManifest.name)
        (self.clock, self.timeout, self.renderer) = (clock, timeout, renderer)
    }

    func prepare() async -> URL? {
        let id = UUID(), deadline = PreparationDeadline(clock: clock, timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                if let active { finish(active.id, .failure(.cancelled)) }
                let previous = verified
                verified = nil
                let worker = Task.detached {
                    let result = await self.run(previous: previous, deadline: deadline)
                    await self.finish(id, result)
                }
                let timer = Task {
                    do { try await clock.sleepUntil(deadline.end) } catch { return }
                    finish(id, .failure(.timeout))
                }
                active = Attempt(id: id, deadline: deadline, worker: worker, timer: timer, waiter: waiter)
                if Task.isCancelled { finish(id, .failure(.cancelled)) }
            }
        } onCancel: { Task { await self.finish(id, .failure(.cancelled)) } }
    }

    // Keep even the synchronous open, ACL walk and JSON decode off the actor that releases the launch waiter.
    private nonisolated func run(previous: VerifiedEnrollment?, deadline: PreparationDeadline) async
        -> Result<VerifiedEnrollment, Failure> {
        do {
            try deadline.check()
            let enrollment = try SelfVoiceEnrollment.load(enrollmentPath)
            try deadline.check()
            return .success(try await publisher.prepare(enrollment, previous: previous, renderer: renderer(enrollment),
                                                        check: deadline.check))
        } catch SelfVoiceEnrollment.Failure.file {
            return .failure(.read)
        } catch is SelfVoiceEnrollment.Failure {
            return .failure(.validation)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.publication)
        }
    }

    private func finish(_ id: UUID, _ result: Result<VerifiedEnrollment, Failure>) {
        guard let attempt = active, attempt.id == id else { return }
        active = nil
        attempt.timer.cancel()
        switch clock.now() >= attempt.deadline.end ? .failure(.timeout) : result {
        case .success(let generation):
            verified = generation
            lastFailure = nil
            attempt.waiter.resume(returning: manifestURL)
        case .failure(let failure):
            attempt.deadline.revoke()
            lastFailure = failure
            attempt.waiter.resume(returning: nil)
            // cancel() invokes arbitrary render cancellation handlers synchronously. Keep those off the spawn waiter.
            Task.detached { attempt.worker.cancel() }
        }
    }
}

// The ordinary reply launcher searches PATH. Enrollment pins the operator's exact wrapper even if it is renamed
// or disappears between validation and spawn. Catalog checks and audio conversion use the slice 1 implementation.
struct EnrolledReplyRenderer: SelfVoiceRendering {
    let enrollment: SelfVoiceEnrollment
    let outputRoot: URL
    let catalog: any SelfVoiceRendering

    init(enrollment: SelfVoiceEnrollment, outputRoot: URL = FileManager.default.temporaryDirectory,
         catalog: (any SelfVoiceRendering)? = nil) {
        self.enrollment = enrollment
        self.outputRoot = outputRoot
        self.catalog = catalog ?? SelfVoiceRenderer(executable: enrollment.executable, outputRoot: outputRoot)
    }

    func profileID(named name: String, at origin: URL) async throws -> String {
        try await catalog.profileID(named: name, at: origin)
    }

    func pcm(for voice: SelfVoiceConfiguration) async throws -> Data {
        let origin = try voice.origin()
        let profile = try await profileID(named: voice.profile, at: origin)
        let executable = try SelfVoiceEnrollment.validatedExecutable(enrollment.executable.path,
                                                                   config: enrollment.file)
        let folder = try OwnedReplyJobDirectory(root: outputRoot)
        guard folder.usable else { throw SelfVoiceError.directory }
        let directory = executable.deletingLastPathComponent().path
        // Keep the wrapper's helpers available only when its directory is a single PATH component.
        let search = directory.contains(":") ? "/usr/bin:/bin" : directory + ":/usr/bin:/bin"
        let environment = ["PATH": search, "VBSAY_ENGINE": "voicebox", "VBSTREAM": "0",
                           "VOICEBOX_URL": origin.absoluteString, "VBSAY_PROFILE": voice.profile,
                           "VBSAY_NOFALLBACK": "1", "no_proxy": String(voice.endpoint.dropFirst("http://".count)),
                           "http_proxy": "http://127.0.0.1:0", "https_proxy": "http://127.0.0.1:0",
                           "PYTHONNOUSERSITE": "1", "VBSAY_NOPLAY": "1", "VBSAY_OUT": folder.url.path,
                           "VBSAY_STDOUT": "1", "VBSAY_CHUNK": "160"]
        let child: RightyoChildProcess.SpawnedChild
        do {
            try Task.checkCancellation()
            child = try RightyoChildProcess.spawn(executable.path, arguments: [SelfVoiceRenderer.passage],
                environment: environment.map { "\($0.key)=\($0.value)" }, directory: folder.url.path)
        } catch {
            _ = folder.remove()
            throw error
        }
        let bytes: Data
        do {
            bytes = try await EnrollmentChild(child).collect()
        } catch {
            // A failed wrapper may leave descendants. Retire only its empty scratch directory in the trusted root.
            _ = rmdir(folder.url.path)
            throw error
        }
        guard folder.remove() else { throw SelfVoiceError.directory }
        guard try await profileID(named: voice.profile, at: origin) == profile else {
            throw SelfVoiceError.configuration
        }
        return bytes
    }
}

/// The exit observer alone reaps. waitid(WNOWAIT) leaves the PID reserved until reap and cancellation meet under the lock.
/// Blocking pipe and kernel waits run off the Swift executor and never hold up the deadline.
private final class EnrollmentChild: Sendable {
    private let pid: pid_t, output: Int32
    private let identity: Mutex<ReplyRendererChildIdentity>
    private let exited = DispatchGroup()
    private let outputQueue = DispatchQueue(label: "hailing.self-voice.stdout")

    init(_ child: RightyoChildProcess.SpawnedChild) {
        pid = child.pid
        output = child.output
        identity = Mutex(ReplyRendererChildIdentity(pid: child.pid))
        close(child.input)
        // Reap on exit even if a descendant inherited a pipe and has not yet closed it.
        exited.enter()
        DispatchQueue(label: "hailing.self-voice.exit").async {
            self.reap()
            self.exited.leave()
        }
        let errors = child.errors
        DispatchQueue(label: "hailing.self-voice.stderr").async { RightyoChildProcess.drainErrors(errors) { _ in } }
    }

    func collect() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { done in
                outputQueue.async {
                    let bytes = Result { try self.readOutput() }
                    if case .failure = bytes { self.cancel() }
                    self.exited.notify(queue: self.outputQueue) {
                        if self.identity.withLock({ $0.status == 0 }) { done.resume(with: bytes) } else {
                            done.resume(throwing: SelfVoiceError.audio)
                        }
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        identity.withLock { $0.signalIfOwned { _ = kill($0, SIGKILL) } }
    }

    private func readOutput() throws -> Data {
        let file = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        var bytes = Data()
        while let chunk = try file.read(upToCount: 32_768), !chunk.isEmpty {
            guard chunk.count <= SelfVoiceWave.maxInput - bytes.count else { throw SelfVoiceError.audio }
            bytes.append(chunk)
        }
        return bytes
    }

    private func reap() {
        var info = siginfo_t()
        var result: Int32
        repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
        identity.withLock { child in
            guard result == 0, info.si_pid == pid else { child.pid = nil; return }
            var status: Int32 = 0
            var observed: pid_t
            repeat { observed = waitpid(pid, &status, 0) } while observed == -1 && errno == EINTR
            _ = child.observe(result: observed, status: status, error: errno)
        }
    }
}
// Enrollment and its exact-path child lifetime share the two-Provider-file slice boundary.
// swiftlint:disable:next file_length
#endif
