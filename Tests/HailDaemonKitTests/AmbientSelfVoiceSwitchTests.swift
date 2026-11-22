#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientSelfVoiceSwitchTests {
    typealias Rig = AmbientSelfVoiceSwitchRig
    @Test func offDoesNotConstructPreparationOrChangeArgv() async throws {
        try await Rig.withRig(enabled: false) { rig in
            rig.start()
            try await rig.expectArgv(manifest: false)
            #expect(rig.constructions == 0 && rig.router.backgroundSelfVoice == nil)
            #expect(!FileManager.default.fileExists(atPath: rig.files.directory.path))
        }
    }

    @Test func firstStartAndConcurrentKicksShareOneHeldRenderThenRestartUsesManifest() async throws {
        let held = HeldSelfVoiceRender()
        try await Rig.withRig(crash: true, renderer: held) { rig in
            defer { held.release() }
            try await held.waitUntilStarted()
            let background = try #require(rig.router.backgroundSelfVoice)
            let flight = try #require(background.inFlight)
            // A valid manifest left by a previous daemon still cannot authorize the first launch.
            try FileManager.default.createDirectory(at: rig.files.directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            try SelfVoiceManifest(version: 1, voices: []).encoded().write(to: rig.files.manifest)
            try #require(chmod(rig.files.manifest.path, 0o600) == 0)
            let start = rig.clock.now
            rig.start()
            try await rig.expectArgv(manifest: false)
            try await rig.expectReason(.pending)
            try await rig.waitForExit()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<32 { group.addTask { background.kick() } }
            }
            #expect(start == rig.clock.now && rig.constructions == 1)
            held.release()
            await flight.value
            rig.start()
            try await rig.expectArgv(manifest: true)
            #expect(rig.attempts == 1)
        }
    }

    @Test func byteOnlyEnrollmentEditKicksPreparationAndNextRestartRecovers() async throws {
        try await Rig.withRig(crash: true) { rig in
            await rig.router.backgroundSelfVoice?.inFlight?.value
            rig.start()
            try await rig.expectArgv(manifest: true)
            try await rig.waitForExit()
            var bytes = try Data(contentsOf: rig.files.file)
            bytes.append(0x20)
            try bytes.write(to: rig.files.file)
            rig.start()
            try await rig.expectArgv(manifest: false)
            try await rig.expectReason(.changed)
            try await rig.waitForExit()
            await rig.router.backgroundSelfVoice?.inFlight?.value
            rig.start()
            try await rig.expectArgv(manifest: true)
            #expect(rig.attempts == 2)
        }
    }

    @Test func removedVoiceNeverReachesAnotherLaunch() async throws {
        try await Rig.withRig(crash: true) { rig in
            await rig.router.backgroundSelfVoice?.inFlight?.value
            #expect(try rig.files.readManifest().voices.map(\.id) == ["one"])
            try rig.files.write([])
            rig.start()
            try await rig.expectArgv(manifest: false)
            try await rig.expectReason(.changed)
            try await rig.waitForExit()
            await rig.router.backgroundSelfVoice?.inFlight?.value
            rig.start()
            try await rig.expectArgv(manifest: true)
            #expect(try rig.files.readManifest().voices.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func replacedManifestMustStillHaveVerifiedBytesAndPrivatePermissions(unsafeMode: Bool) async throws {
        try await Rig.withRig { rig in
            await rig.router.backgroundSelfVoice?.inFlight?.value
            var bytes = try Data(contentsOf: rig.files.manifest)
            if !unsafeMode { bytes.append(0x20) }
            try bytes.write(to: rig.files.manifest, options: .atomic)
            try #require(chmod(rig.files.manifest.path, unsafeMode ? 0o644 : 0o600) == 0)
            rig.start()
            try await rig.expectArgv(manifest: false)
            try await rig.expectReason(.mismatch)
        }
    }

    @Test(arguments: [false, true])
    func reloadFinishesWithRendererStillHeld(overSocket: Bool) async throws {
        let held = HeldSelfVoiceRender()
        try await Rig.withRig(renderer: held) { rig in
            defer { held.release() }
            try await held.waitUntilStarted()
            let now = rig.clock.now
            let stream = rig.start()
            let first = try await rig.expectArgv(manifest: false)
            let before = Data(repeating: 0x11, count: 320)
            rig.router.ambientAudio(.segment(stream: stream, sequence: 0, bytes: before))
            // Cross the server submission budget on the preparation clock, without releasing the renderer.
            rig.clock.advance(by: .seconds(12))
            if overSocket {
                #expect(try await rig.socketReload().ambient?.outcome == .reloaded)
            } else {
                #expect(await rig.router.reload() == .reloaded)
            }
            let second = try await rig.expectArgv(manifest: false)
            #expect(try await rig.recordedAudio(first) == before)
            let after = Data(repeating: 0x22, count: 320)
            rig.router.ambientAudio(.segment(stream: stream, sequence: 1, bytes: after))
            rig.router.ambientAudio(.ended(stream: stream, reason: .final))
            #expect(try await rig.recordedAudio(second) == after)
            #expect(rig.clock.now == now + .seconds(12) && rig.attempts == 1)
        }
    }

    @Test func anotherConnectionTakesOverBeforeRendererReturns() async throws {
        let held = HeldSelfVoiceRender()
        try await Rig.withRig(renderer: held) { rig in
            defer { held.release() }
            try await held.waitUntilStarted()
            let now = rig.clock.now
            let old = rig.start()
            try await rig.expectArgv(manifest: false)
            rig.router.ambientAudio(.ended(stream: old, reason: .superseded))
            let next = UUID()
            rig.start(on: next)
            try await rig.expectArgv(manifest: false)
            #expect(rig.router.activeConnection() == next && rig.clock.now == now)
        }
    }

    static let refused: [[String]] = {
        let base = AmbientWiringOptionsTests.base, personal = AmbientWiringOptionsTests.personal
        let group = AmbientWiringOptionsTests.ambient, full = base + personal + group
        let flag = ["--ambient-self-voice"], valid = flag + ["/enrollment.json"]
        let badValues = [flag, flag + [""], flag + ["relative"], flag + ["--ambient-target"],
                         valid + valid, valid + ["extra"]]
        let incomplete = [[], Array(group.dropFirst(2)), Array(group.prefix(2)) + Array(group.suffix(2)),
                          Array(group.dropLast(2))]
        let missingPrerequisites = [["--personal-terminal"], ["--connection-probe", "--single-terminal-reply-fallback"]]
        return badValues.map { full + $0 } + incomplete.map { base + personal + $0 + valid }
            + missingPrerequisites.map { base + $0 + group + valid }
    }()

    @Test(arguments: refused)
    func invalidSwitchUsesDaemonArgumentError(_ arguments: [String]) {
        #expect(throws: WebSocketListenerError.invalidArguments) { try ConnectionProbeDaemon.options(arguments) }
    }
}
#endif
