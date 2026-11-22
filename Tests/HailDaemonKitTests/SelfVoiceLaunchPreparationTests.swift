#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

extension SyntheticSelfVoice: SelfVoiceEnrollmentRendering {
    func pcm(for voice: SelfVoiceConfiguration, verifying profileID: String) throws -> Data {
        guard try self.profileID(named: voice.profile, at: voice.origin()) == profileID else {
            throw SelfVoiceError.configuration
        }
        return pcm(for: voice)
    }
}

extension SelfVoiceLaunchPreparation {
    init(enrollmentPath: String, directory: String, clock: TaskProgressClock, timeout: Duration = .seconds(20),
         renderer: @escaping Renderer) {
        self.init(enrollmentPath: enrollmentPath, publisher: SelfVoicePublisher(directory: directory, clock: { 100 }),
                  clock: clock, timeout: timeout, renderer: renderer)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SelfVoiceLaunchPreparationTests {
    struct Rig {
        let files: EnrollmentFixture
        let renderer = SyntheticSelfVoice(), clock = ProgressTestClock()
        let preparation: SelfVoiceLaunchPreparation

        init() throws {
            files = try EnrollmentFixture()
            preparation = .init(enrollmentPath: files.file.path, directory: files.directory.path, clock: clock.clock,
                                renderer: { [renderer, executable = files.executable] enrollment in
                #expect(enrollment.executable == executable)
                return renderer
            })
        }
    }

    @Test func reusesVerifiedGenerationAndRendersOnlyChangedRevision() async throws {
        let rig = try Rig(), files = rig.files, voice = EnrollmentFixture.voice
        defer { files.remove() }
        let two = voice.merging(["id": "two"]) { $1 }
        try files.write([voice, two])
        #expect(await rig.preparation.prepare() == files.manifest)
        let first = try files.readManifest()
        var before = stat(), after = stat()
        try #require(lstat(files.manifest.path, &before) == 0)
        #expect(await rig.preparation.prepare() == files.manifest)
        try #require(lstat(files.manifest.path, &after) == 0)
        #expect(before.st_ino == after.st_ino)
        #expect(await rig.renderer.calls == ["one", "two"])
        try files.write([voice.merging(["revision": "2"]) { $1 }, two])
        #expect(await rig.preparation.prepare() == files.manifest)
        let second = try files.readManifest()
        try #require(first.voices.count == 2 && second.voices.count == 2)
        #expect(second.voices[0].renderedAt > first.voices[0].renderedAt && first.voices[1] == second.voices[1])
        try files.write([two])
        #expect(await rig.preparation.prepare() == files.manifest)
        #expect(try files.readManifest().voices == [second.voices[1]])
        try files.write([])
        #expect(await rig.preparation.prepare() == files.manifest)
        #expect(try files.readManifest().voices.isEmpty)
        #expect(await rig.renderer.calls == ["one", "two", "one"])
        #expect(await rig.preparation.lastFailure == nil)
    }

    @Test func rerendersWhenTheSameNameResolvesToANewID() async throws {
        let rig = try Rig()
        defer { rig.files.remove() }
        try #require(await rig.preparation.prepare() == rig.files.manifest)
        let original = try #require(try rig.files.readManifest().voices.first)
        await rig.renderer.replaceProfile(named: "Local (one)", id: "new-id")
        try #require(await rig.preparation.prepare() == rig.files.manifest)
        let replacement = try #require(try rig.files.readManifest().voices.first)
        #expect(replacement.file != original.file)
        #expect(replacement.renderedAt > original.renderedAt)
        #expect(await rig.preparation.prepare() == rig.files.manifest)
        #expect(try rig.files.readManifest().voices == [replacement])
        #expect(await rig.renderer.calls == ["one", "one"])
    }

    @Test func staleDiskManifestNeverAuthorizesLaunchAndRecoveryRendersAgain() async throws {
        let rig = try Rig(), files = rig.files
        defer { files.remove() }
        _ = try #require(await rig.preparation.prepare())
        let stale = try files.readManifest()
        let restarted = SelfVoiceLaunchPreparation(enrollmentPath: files.file.path, directory: files.directory.path,
                                                   clock: rig.clock.clock, renderer: { _ in rig.renderer })
        try FileManager.default.removeItem(at: files.file)
        #expect(await restarted.prepare() == nil)
        #expect(await restarted.lastFailure == .read)
        #expect(try files.readManifest() == stale)

        try files.write([], path: "relative")
        #expect(await rig.preparation.prepare() == nil)
        #expect(await rig.preparation.lastFailure == .validation)
        try files.write()
        #expect(await rig.preparation.prepare() == files.manifest)
        #expect(try files.readManifest() != stale)
        #expect(await rig.renderer.calls == ["one", "one"])
    }

    @Test func catalogFailureAndTamperedWaveWithholdVerifiedPath() async throws {
        let rig = try Rig(), files = rig.files
        defer { files.remove() }
        _ = try #require(await rig.preparation.prepare())
        let entry = try #require(try files.readManifest().voices.first)
        try Data([0]).write(to: files.directory.appendingPathComponent(entry.file))
        #expect(await rig.preparation.prepare() == nil)
        #expect(await rig.preparation.lastFailure == .publication)
        #expect(await rig.preparation.prepare() == files.manifest)
        #expect(await rig.renderer.calls == ["one", "one"])
        await rig.renderer.addProfile(id: "another", name: "Local (one)")
        #expect(await rig.preparation.prepare() == nil)
        #expect(await rig.preparation.lastFailure == .render)
    }

    @Test func timeoutTerminatesOnlyItsRenderAndLateCompletionCannotPublish() async throws {
        let files = try EnrollmentFixture(), clock = ProgressTestClock(), held = HeldRender()
        defer { files.remove() }
        let normal = SyntheticSelfVoice()
        let preparations = Mutex(0)
        let prepare = SelfVoiceLaunchPreparation(enrollmentPath: files.file.path, directory: files.directory.path,
                                                clock: clock.clock, timeout: .seconds(7)) { _ in
            let first = preparations.withLock { count in count += 1; return count == 1 }
            if first { return held }
            return normal
        }
        let start = clock.now
        let result = Task { await prepare.prepare() }
        var started = held.started.stream.makeAsyncIterator()
        _ = try #require(await started.next())
        let retiring = try #require(await prepare.inFlightWork)
        clock.advance(by: .seconds(7))
        #expect(await result.value == nil)
        #expect(clock.now == start + .seconds(7))
        #expect(await prepare.lastFailure == .timeout)
        var terminated = held.terminated.stream.makeAsyncIterator()
        _ = try #require(await terminated.next())
        #expect(!FileManager.default.fileExists(atPath: files.manifest.path))

        // The old render still holds its PCM. A new generation must succeed independently.
        try files.write([EnrollmentFixture.voice.merging(["id": "replacement"]) { $1 }])
        #expect(await prepare.prepare() == files.manifest)
        let fresh = try files.readManifest()
        #expect(fresh.voices.map(\.id) == ["replacement"])
        held.release()
        await retiring.value
        #expect(try files.readManifest() == fresh)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: files.directory.path))
            == Set(fresh.voices.map(\.file) + [SelfVoiceManifest.name]))
        #expect(await prepare.prepare() == files.manifest)
        #expect(await normal.calls == ["replacement"])
    }
}

private final class HeldRender: SelfVoiceEnrollmentRendering {
    let started = AsyncStream<Void>.makeStream(), terminated = AsyncStream<Void>.makeStream()
    private let pending = Mutex<CheckedContinuation<Void, Never>?>(nil)

    func profileID(named name: String, at origin: URL) -> String { name }

    func pcm(for voice: SelfVoiceConfiguration, verifying profileID: String) async throws -> Data {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                pending.withLock { $0 = waiter }
                started.continuation.yield(())
            }
        } onCancel: { self.terminated.continuation.yield(()) }
        // Deliberately returns otherwise valid PCM even after the synthetic child was terminated.
        return Data(count: 8 * 48_000)
    }

    func release() { pending.withLock { $0?.resume(); $0 = nil } }
}
#endif
