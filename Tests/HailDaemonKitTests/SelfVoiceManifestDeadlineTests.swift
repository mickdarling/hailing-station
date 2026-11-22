#if os(macOS)
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)))
struct SelfVoiceManifestDeadlineTests {
    @Test func unrelatedTasksFinishWhileManifestRenameIsBlocked() async throws {
        let files = try EnrollmentFixture()
        defer { files.remove() }
        let gate = RenameGate(at: .beforeRenameCheck)
        let preparation = gate.preparation(files, clock: ProgressTestClock(), renderer: SyntheticSelfVoice())
        let launch = try await gate.start(preparation)

        let completed = await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { await Task.yield() }
            }
            var count = 0
            for await _ in group { count += 1 }
            return count
        }
        #expect(completed == 64)
        #expect(!FileManager.default.fileExists(atPath: files.manifest.path))
        gate.release.signal()
        #expect(await launch.value == files.manifest)
    }

    @Test func expiryBeforeRenameCheckRollsBackNewWaves() async throws {
        let files = try EnrollmentFixture(), clock = ProgressTestClock(), renderer = SyntheticSelfVoice()
        defer { files.remove() }
        let first = SelfVoiceLaunchPreparation(enrollmentPath: files.file.path, directory: files.directory.path,
                                               clock: clock.clock, renderer: { _ in renderer })
        try #require(await first.prepare() == files.manifest)
        let previous = try Data(contentsOf: files.manifest)
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: files.directory.path))
        try files.write([EnrollmentFixture.voice.merging(["id": "replacement"]) { $1 }])

        let gate = RenameGate(at: .beforeRenameCheck)
        let preparation = gate.preparation(files, clock: clock, renderer: renderer)
        let worker = try await gate.expire(preparation, clock: clock)
        do {
            defer { gate.release.signal() }
            let staged = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
            #expect(staged.filter { $0.hasSuffix(".wav") && !names.contains($0) }.count == 1)
        }
        await worker.value

        #expect(try Data(contentsOf: files.manifest) == previous)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: files.directory.path)) == names)
    }

    @Test func expiryAfterRenameCheckRequiresFreshVerificationForNextLaunch() async throws {
        let files = try EnrollmentFixture(), clock = ProgressTestClock(), renderer = SyntheticSelfVoice()
        defer { files.remove() }
        let gate = RenameGate(at: .renameAuthorized)
        let preparation = gate.preparation(files, clock: clock, renderer: renderer)
        let worker = try await gate.expire(preparation, clock: clock)
        #expect(!FileManager.default.fileExists(atPath: files.manifest.path))
        gate.release.signal()
        await worker.value

        let late = try files.readManifest()
        try #require(late.voices.map(\.id) == ["one"])
        for entry in late.voices {
            let bytes = try Data(contentsOf: files.directory.appendingPathComponent(entry.file))
            #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == entry.sha256)
        }
        #expect(await preparation.lastFailure == .timeout)
        let beforeRetry = gate.verifications.withLock { $0 }
        try files.write([EnrollmentFixture.voice.merging(["id": "fresh"]) { $1 }])
        #expect(await preparation.prepare() == files.manifest)
        #expect(gate.verifications.withLock { $0 } == beforeRetry + 1)
        #expect(try files.readManifest().voices.map(\.id) == ["fresh"])
    }
}

private final class RenameGate: Sendable {
    let release = DispatchSemaphore(value: 0)
    let verifications = Mutex(0)
    private let event: SelfVoiceDirectory.LaunchEvent
    private let reached = AsyncStream<Void>.makeStream()
    private let armed = Mutex(true)

    init(at event: SelfVoiceDirectory.LaunchEvent) { self.event = event }

    private func observe(_ step: SelfVoiceDirectory.LaunchEvent) {
        if step == .manifestVerified { verifications.withLock { $0 += 1 } }
        guard step == event, armed.withLock({ armed in
            defer { armed = false }
            return armed
        }) else { return }
        reached.continuation.yield(())
        // A failed watchdog exposes a caller waiting on the filesystem gate.
        #expect(release.wait(timeout: .now() + 10) == .success)
    }

    func preparation(_ files: EnrollmentFixture, clock: ProgressTestClock,
                     renderer: SyntheticSelfVoice) -> SelfVoiceLaunchPreparation {
        let publisher = SelfVoicePublisher(directory: files.directory.path, observeLaunch: observe)
        return SelfVoiceLaunchPreparation(enrollmentPath: files.file.path, publisher: publisher,
                                          clock: clock.clock, timeout: .seconds(7), renderer: { _ in renderer })
    }

    func start(_ preparation: SelfVoiceLaunchPreparation) async throws -> Task<URL?, Never> {
        let launch = Task {
            defer { reached.continuation.finish() }
            return await preparation.prepare()
        }
        var arrivals = reached.stream.makeAsyncIterator()
        _ = try #require(await arrivals.next())
        return launch
    }

    func expire(_ preparation: SelfVoiceLaunchPreparation, clock: ProgressTestClock) async throws -> Task<Void, Never> {
        let deadline = clock.now + .seconds(7)
        let launch = try await start(preparation)
        let worker = try #require(await preparation.inFlightWorker?.task)
        clock.advance(by: .seconds(7))
        #expect(await launch.value == nil)
        #expect(clock.now == deadline)
        #expect(await preparation.lastFailure == .timeout)
        return worker
    }
}
#endif
