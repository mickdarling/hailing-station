#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientSelfVoiceSwitchTests {
    typealias Rig = AmbientSelfVoiceSwitchRig
    typealias Failure = SelfVoiceLaunchPreparation.Failure

    @Test func offDoesNotConstructPreparationOrChangeArgv() async throws {
        try await Rig.withRig(enabled: false) { rig in
            rig.start()
            try await rig.expectArgv(manifest: false)
            #expect(rig.constructions == 0)
            #expect(!FileManager.default.fileExists(atPath: rig.files.directory.path))
            #expect(rig.failures.isEmpty)
        }
    }

    @Test func nextStartAfterCrashRechecksEnrollmentDespiteStaleManifest() async throws {
        try await Rig.withRig(crash: true) { rig in
            rig.start()
            try await rig.expectArgv(manifest: true)
            try await rig.waitForCrash()
            let stale = try Data(contentsOf: rig.files.manifest)
            try FileManager.default.removeItem(at: rig.files.file)
            rig.start()
            try await rig.expectArgv(manifest: false)
            #expect(try Data(contentsOf: rig.files.manifest) == stale)
            #expect(rig.constructions == 1)
            #expect(rig.failures == [Self.off(.read)])
        }
    }

    @Test(arguments: [Failure.validation, .render, .publication, .cancelled])
    func reloadPreparesAgainAndKeepsVoiceAvailable(on failure: Failure) async throws {
        try await Rig.withRig { rig in
            rig.start()
            try await rig.expectArgv(manifest: true)
            try await rig.waitForLaunchSlot()
            switch failure {
            case .validation: try rig.files.write(object: ["version": 0])
            case .render: try rig.files.write([EnrollmentFixture.voice.merging(["profile": "absent"]) { $1 }])
            case .publication:
                let entry = try #require(try rig.files.readManifest().voices.first)
                try Data([0]).write(to: rig.files.directory.appendingPathComponent(entry.file))
            case .cancelled: break
            default:
                Issue.record("Unexpected reload fixture")
                return
            }
            let reload = Task {
                if failure == .cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                return await rig.router.reload()
            }
            #expect(await reload.value == .reloaded)
            try await rig.expectArgv(manifest: false)
            #expect(rig.constructions == 1)
            #expect(rig.failures == [Self.off(failure)])
        }
    }

    @Test func childStartsAtDeadlineWithRenderStillSuspended() async throws {
        let held = HeldSelfVoiceRender()
        try await Rig.withRig(renderer: held) { rig in
            defer { held.release() }
            rig.start()
            var started = held.started.stream.makeAsyncIterator()
            _ = try #require(await started.next())
            let preparation = try #require(rig.router.configuration.selfVoice)
            let worker = try #require(await preparation.inFlightWork)
            #expect(rig.router.liveRuns == 0)
            let deadline = rig.clock.now + .seconds(20)
            rig.clock.advance(by: .seconds(20))
            try await rig.expectArgv(manifest: false)
            #expect(rig.clock.now == deadline)
            #expect(rig.failures == [Self.off(.timeout)])
            held.release()
            await worker.value
        }
    }

    private static func off(_ failure: Failure) -> WebSocketListenerEvent {
        .init(event: "self-voice", detail: "off for this child (\(failure.rawValue))")
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
