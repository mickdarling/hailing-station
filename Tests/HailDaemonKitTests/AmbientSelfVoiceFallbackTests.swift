#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientSelfVoiceFallbackTests {
    typealias Rig = AmbientSelfVoiceSwitchRig

    @Test(arguments: [false, true])
    func verifiedGenerationWithHeldReadLaunchesOrdinaryChild(holdManifest: Bool) async throws {
        let gate = RecipientPublicationGate(timeout: .seconds(10))
        let hooks = Rig.Hooks(read: { path, manifest in
            if manifest == holdManifest { _ = gate.block(onDedicatedQueue: true) }
            return try SelfVoicePrivateFile.boundedBytes(path, privateDirectory: manifest)
        })
        try await Rig.withRig(hooks: hooks) { rig in
            defer { gate.release() }
            await rig.router.backgroundSelfVoice?.inFlight?.value
            try #require(rig.attempts == 1)
            let launch = Task { rig.start() }
            try await gate.waitEntered()
            _ = await launch.value
            try await rig.expectArgv(manifest: false)
            try await rig.expectReason(.pending)
            await rig.router.backgroundSelfVoice?.inFlight?.value
            #expect(rig.attempts == 2)
            #expect(!gate.timedOut)
            gate.release()
        }
    }

    @Test func heldSinkRetainsEveryReasonAndOccurrence() async throws {
        let gate = RecipientPublicationGate(timeout: .seconds(10))
        defer { gate.release() }
        let output = AsyncStream<SelfVoiceFallback>.makeStream()
        let log = SelfVoiceFallbackLog(queue: DispatchQueue(label: "synthetic.fallbacks")) { reason in
            if reason == .pending { _ = gate.block(onDedicatedQueue: true) }
            output.continuation.yield(reason)
        }
        log.enqueue(.pending)
        try await gate.waitEntered()
        let reasons: [SelfVoiceFallback] = [.changed, .mismatch, .preparation(.read), .preparation(.validation),
                                            .preparation(.render), .preparation(.publication),
                                            .preparation(.timeout), .preparation(.cancelled)]
        for _ in 0..<5 {
            for reason in reasons { log.enqueue(reason) }
        }
        gate.release()
        var lines = output.stream.makeAsyncIterator(), counts = [SelfVoiceFallback: Int]()
        for _ in 0..<(1 + 5 * reasons.count) {
            let reason = try #require(await lines.next())
            counts[reason, default: 0] += 1
        }
        #expect(counts[.pending] == 1)
        for reason in reasons { #expect(counts[reason] == 5) }
        #expect(!gate.timedOut)
    }

    @Test(arguments: [false, true])
    func refusedReloadDeliversInterveningPCMToConfirmedPrivateChild(enabled: Bool) async throws {
        try await Rig.withRig(enabled: enabled) { rig in
            await rig.router.backgroundSelfVoice?.inFlight?.value
            try rig.fake.install(fixture: "enrolled-formed-request.jsonl")
            let behavior = rig.fake.directory.appendingPathComponent("behavior.sh")
            let started = #"/usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g""#
                + FakeRightyo.duckV3
            let script = [AmbientPrivacyEntryTests.startPrivatePrelude, started,
                          try String(contentsOf: behavior, encoding: .utf8)].joined(separator: "\n")
            try Data(script.utf8).write(to: behavior)
            let router = rig.router, notices = AsyncStream<Void>.makeStream()
            router.mediaNotices.enqueue { for await _ in notices.stream { break } }
            defer { notices.continuation.finish() }
            router.ambientPrivacyPreArm(connection: rig.connection)
            let stream = rig.start()
            let session = try await rig.expectArgv(manifest: enabled, startPrivate: true)
            try #require(await router.privacyKept(connection: rig.connection))
            try FileManager.default.removeItem(at: rig.fake.config)
            let before = Data([1, 2]), during = Data([3, 4]), after = Data([5, 6])
            router.ambientAudio(.segment(stream: stream, sequence: 0, bytes: before))
            let outcome = await router.reload(afterClaim: {
                router.ambientAudio(.segment(stream: stream, sequence: 1, bytes: during))
            })
            try #require(outcome == .refused("child unsafeConfig"))
            router.ambientAudio(.segment(stream: stream, sequence: 2, bytes: after))
            router.ambientAudio(.ended(stream: stream, reason: .final))
            #expect(try await rig.recordedAudio(session) == before + during + after)
        }
    }
}
#endif
