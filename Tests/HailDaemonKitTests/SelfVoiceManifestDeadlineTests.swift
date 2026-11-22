#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)))
struct SelfVoiceManifestDeadlineTests {
    @Test func expiryAtRenamePreservesThePreviousManifestAfterWorkerRetires() async throws {
        let files = try EnrollmentFixture(), clock = ProgressTestClock(), renderer = SyntheticSelfVoice()
        defer { files.remove() }
        let first = SelfVoiceLaunchPreparation(enrollmentPath: files.file.path, directory: files.directory.path,
                                               clock: clock.clock, renderer: { _ in renderer })
        try #require(await first.prepare() == files.manifest)
        let previous = try Data(contentsOf: files.manifest)
        try files.write([])

        let reached = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let replace: SelfVoiceDirectory.ReplaceManifest = { directory, temp, name in
            reached.continuation.yield(())
            // The watchdog fails a timer that tries to wait for the filesystem gate.
            #expect(release.wait(timeout: .now() + 10) == .success)
            try SelfVoiceDirectory.renameManifest(in: directory, from: temp, to: name)
        }
        let publisher = SelfVoicePublisher(directory: files.directory.path, replaceLaunchManifest: replace)
        let preparation = SelfVoiceLaunchPreparation(enrollmentPath: files.file.path, publisher: publisher,
                                                      clock: clock.clock, timeout: .seconds(7), renderer: { _ in
            renderer
        })
        let launch = Task {
            defer { reached.continuation.finish() }
            return await preparation.prepare()
        }
        var arrivals = reached.stream.makeAsyncIterator()
        _ = try #require(await arrivals.next())
        let worker = try #require(await preparation.inFlightWork)
        clock.advance(by: .seconds(7))
        #expect(await launch.value == nil)
        #expect(await preparation.lastFailure == .timeout)
        #expect(try Data(contentsOf: files.manifest) == previous)
        release.signal()
        await worker.value
        #expect(try Data(contentsOf: files.manifest) == previous)
    }
}
#endif
