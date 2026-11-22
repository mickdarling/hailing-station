#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientSelfVoiceIsolationTests {
    typealias Rig = AmbientSelfVoiceSwitchRig

    @Test func blockedFallbackLogDoesNotDelaySpawnOrReload() async throws {
        let gate = RecipientPublicationGate(timeout: .seconds(10))
        let held = HeldSelfVoiceRender()
        try await Rig.withRig(renderer: held, logGate: gate) { rig in
            defer { gate.release(); held.release() }
            try await held.waitUntilStarted()
            let launch = Task { rig.start() }
            try await gate.waitEntered()
            try await rig.expectArgv(manifest: false)
            _ = await launch.value
            #expect(await rig.router.reload() == .reloaded)
            try await rig.expectArgv(manifest: false)
            #expect(!gate.timedOut)
        }
    }

    @Test func deadlineRevokesEvenWhenRendererIgnoresCancellation() async throws {
        let held = HeldSelfVoiceRender()
        try await Rig.withRig(renderer: held) { rig in
            defer { held.release() }
            try await held.waitUntilStarted()
            let flight = try #require(rig.router.backgroundSelfVoice?.inFlight)
            rig.clock.advance(by: .seconds(20))
            var cancelled = held.terminated.stream.makeAsyncIterator()
            _ = try #require(await cancelled.next())
            rig.start()
            try await rig.expectArgv(manifest: false)
            try await rig.expectReason(.pending)
            held.release()
            await flight.value
            #expect(rig.attempts == 1)
            #expect(!FileManager.default.fileExists(atPath: rig.files.manifest.path))
        }
    }

    @Test func shutdownCancelsWithoutJoiningAHeldRenderer() async throws {
        let held = HeldSelfVoiceRender()
        try await Rig.withRig(renderer: held) { rig in
            defer { held.release() }
            try await held.waitUntilStarted()
            let flight = try #require(rig.router.backgroundSelfVoice?.inFlight)
            await rig.router.shutdown()
            var cancelled = held.terminated.stream.makeAsyncIterator()
            _ = try #require(await cancelled.next())
            held.release()
            await flight.value
            #expect(!FileManager.default.fileExists(atPath: rig.files.manifest.path))
        }
    }

    @Test(arguments: [SelfVoiceLaunchPreparation.Failure.read, .validation, .render])
    func failedRepreparationCannotPassStaleManifest(_ failure: SelfVoiceLaunchPreparation.Failure) async throws {
        try await Rig.withRig(crash: true) { rig in
            await rig.router.backgroundSelfVoice?.inFlight?.value
            let stale = try Data(contentsOf: rig.files.manifest)
            switch failure {
            case .read: try FileManager.default.removeItem(at: rig.files.file)
            case .validation: try rig.files.write(object: ["version": 0])
            case .render: try rig.files.write([EnrollmentFixture.voice.merging(["profile": "missing"]) { $1 }])
            default: Issue.record("Unexpected failure fixture"); return
            }
            for _ in 0..<2 {
                rig.start()
                try await rig.expectArgv(manifest: false)
                try await rig.expectReason(.changed)
                try await rig.waitForExit()
                await rig.router.backgroundSelfVoice?.inFlight?.value
                #expect(await rig.router.configuration.selfVoice?.lastFailure == failure)
            }
            #expect(try Data(contentsOf: rig.files.manifest) == stale)
        }
    }

    @Test func publicChildGetsOnlyPostToggleBytesAfterQueuedPrivateStart() async throws {
        let held = HeldSelfVoiceRender()
        try await Rig.withRig(renderer: held) { rig in
            defer { held.release() }
            try await held.waitUntilStarted()
            let flight = try #require(rig.router.backgroundSelfVoice?.inFlight)
            let router = rig.router
            // This fixture has no peer socket. Hold the device notice so a no-connection response
            // cannot disarm the real pre-arm ahead of the owner's explicit switch off.
            let notices = AsyncStream<Void>.makeStream()
            router.mediaNotices.enqueue { for await _ in notices.stream { break } }
            defer { notices.continuation.finish() }
            router.ambientPrivacyPreArm(connection: rig.connection)
            try #require(router.duckMode(connection: rig.connection))

            // Model an occupied reload slot to exercise ordered admission deterministically, even though
            // the held renderer no longer provides such a slot. No child can accept these private bytes.
            router.state.withLock { $0.reloading = true }
            defer { router.state.withLock { $0.reloading = false } }
            let stream = rig.start()
            let privateBytes = Data(repeating: 0x71, count: 32)
            for sequence in 0..<3 {
                router.ambientAudio(.segment(stream: stream, sequence: sequence, bytes: privateBytes))
            }
            _ = router.setDuck(false, connection: rig.connection, reason: "device")
            try #require(!router.duckMode(connection: rig.connection))
            held.release()
            await flight.value
            router.state.withLock { $0.reloading = false }
            let publicBytes = Data(repeating: 0x42, count: 32)
            router.ambientAudio(.segment(stream: stream, sequence: 3, bytes: publicBytes))
            let session = try await rig.expectArgv(manifest: true)
            router.ambientAudio(.ended(stream: stream, reason: .final))
            #expect(try await rig.recordedAudio(session) == publicBytes)
        }
    }
}
#endif
