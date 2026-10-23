#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Privacy mode (#735 S-2b, internally duck): while privacy is on, every RightyO child is launched with its
/// start-private option, and one whose `started` does not confirm `"private": true` is killed, never admitted.
/// Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyStartPrivateTests {
    static let confirmed = #"{"type": "session", "phase": "started", "duck": {"version": 2, "private": true}}"#

    @Test func theOptionIsRightyosStartPrivate() {
        #expect(RightyoChildProcess.startPrivateFlag == "--start-private")
        let config = URL(fileURLWithPath: "/synthetic/config.json")
        #expect(!RightyoChildProcess.arguments(session: "hail-test", config: config, replyControl: true)
            .contains(RightyoChildProcess.startPrivateFlag))
    }

    /// Started private and confirmed: the wish was on from the first line, and nothing more is written.
    @Test func aConfirmedStartIsKeptAndNotWritten() {
        let (control, written) = (AmbientDuckControl(startPrivate: true), AmbientDuckControlTests.Written())
        #expect(control.active)
        #expect(control.observe(started: Data(Self.confirmed.utf8), write: written.write) == .kept)
        #expect(control.active && written.all.isEmpty)
        #expect(control.report(false, write: written.write) && !control.active)
        #expect(written.all == [false])
    }

    /// Privacy that ended while the child was starting is written off once the child confirms it started private.
    @Test func aConfirmedStartWhosePrivacyEndedIsWrittenOff() {
        let (control, written) = (AmbientDuckControl(startPrivate: true), AmbientDuckControlTests.Written())
        #expect(control.report(false, write: written.write))
        #expect(control.observe(started: Data(Self.confirmed.utf8), write: written.write) == .kept)
        #expect(written.all == [false])
    }

    @Test(arguments: [
        #"{"type": "session", "phase": "started"}"#,
        #"{"type": "session", "phase": "started", "duck": {"version": 2}}"#,
        #"{"type": "session", "phase": "started", "duck": {"version": 2, "private": false}}"#,
        #"{"type": "session", "phase": "started", "duck": {"version": 2, "private": "true"}}"#,
        #"{"type": "session", "phase": "started", "duck": {"version": 2, "private": 1}}"#,
        #"{"type": "session", "phase": "started", "duck": {"version": 1, "private": true}}"#,
        #"{"type": "session", "phase": "started", "private": true, "duck": {"version": 2}}"#
    ])
    func anythingElseIsUnconfirmedAndStaysHeld(_ line: String) {
        let (control, written) = (AmbientDuckControl(startPrivate: true), AmbientDuckControlTests.Written())
        #expect(control.observe(started: Data(line.utf8), write: written.write) == .refused)
        #expect(control.active && written.all.isEmpty)
        #expect(!control.report(true, write: written.write) && written.all.isEmpty)
    }

    /// A pipeline launched start-private whose child does not confirm it throws `privacyUnconfirmed`, with the child
    /// killed and reaped, and never dispatches the request the child goes on to form.
    @Test func anUnconfirmedChildIsKilledAndNothingIsDelivered() async throws {
        let fake = try FakeRightyo(AmbientPrivacyEntryTests.fixture(saying: "Rightyo, archive the project.",
                                                                    advertises: false))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        (configuration.replyControl, configuration.startPrivate) = (true, true)
        configuration.onVoiceDuck = { _ in }
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        await #expect(throws: RightyoPrivacyRefusal.unconfirmedStart) { _ = try await pipeline.run() }
        #expect(await dispatcher.requests.isEmpty)
    }

    /// A new stream on a connection that is private (a respawn) launches its child start-private too.
    @Test func aRespawnWhilePrivateStartsPrivate() async throws {
        let script = "echo \"$*\" >> argv.txt\n/bin/cat <&3 >> control.txt &\n" + AmbientDuckReloadTests.entry
        let rig = try await DuckRig(script: script)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        try await recipientSocketSend(audio(rig.stream, 1, final: true), on: rig.socket)
        #expect(await eventually { rig.details("ambient_ended").count == 1 })
        let next = UUID()
        try await recipientSocketSend(audio(next, 0), on: rig.socket)
        #expect(await eventually { rig.details("ambient_started").count == 2 })
        #expect(rig.env.router.duckMode(connection: connection))
        #expect(await eventually {
            let launches = ((try? rig.fake.recorded("argv.txt")) ?? "").split(separator: "\n")
            return launches.count == 2 && launches.last?.hasSuffix("--start-private") == true
        })
        let first = try rig.fake.recorded("argv.txt").split(separator: "\n").first
        #expect(first?.contains("--start-private") == false)
        try await recipientSocketSend(audio(next, 1, final: true), on: rig.socket)
        await rig.env.router.settle()
        #expect(rig.details("ambient_privacy_start").isEmpty)
        await rig.env.listener.stop(reason: "synthetic test complete")
    }

    // MARK: Round 2: no `lost` (#735 S-2b)

    /// A pipeline launched for one stream on the given script, with privacy wished for as `startPrivate` says.
    static func pipeline(_ fake: FakeRightyo, startPrivate: Bool, deadline: TimeInterval = 10)
        throws -> (RightyoAmbientPipeline, RecordingAmbientDispatcher) {
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        (configuration.replyControl, configuration.startPrivate) = (true, startPrivate)
        (configuration.onVoiceDuck, configuration.startDeadline) = ({ _ in }, deadline)
        let dispatcher = RecordingAmbientDispatcher()
        return (try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher), dispatcher)
    }

    /// Key 1: a start-private child that never says `started` is killed at the deadline and refused.
    @Test func aChildThatNeverStartsIsKilledAtTheDeadline() async throws {
        let fake = try FakeRightyo("echo $$ > child.pid\n/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let (pipeline, dispatcher) = try Self.pipeline(fake, startPrivate: true, deadline: 0.3)
        let started = ContinuousClock.now
        await #expect(throws: RightyoPrivacyRefusal.unconfirmedStart) { _ = try await pipeline.run() }
        #expect(started.duration(to: .now) < .seconds(8))
        #expect(await dispatcher.requests.isEmpty)
        let pid = try #require(Int32(fake.recorded("child.pid").trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { kill(pid, 0) != 0 })
    }

    /// The spawn-to-started race: a child launched public, privacy wished for before its `started`, and no `duck` v2.
    /// It is killed and refused, never `lost`: privacy stays wished and nothing is delivered.
    @Test(arguments: [nil, 1] as [Int?]) func theSpawnToStartedRaceIsRefused(_ version: Int?) async throws {
        let fake = try FakeRightyo("/bin/sleep 0.5\n" + AmbientPrivacyEntryTests.fixture(
            saying: "Rightyo, archive the project.", advertises: version != nil, version: version ?? 1))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let (pipeline, dispatcher) = try Self.pipeline(fake, startPrivate: false)
        #expect(pipeline.reportDuck(true))
        await #expect(throws: RightyoPrivacyRefusal.unsupportedChild) { _ = try await pipeline.run() }
        #expect(await dispatcher.requests.isEmpty)
    }

    /// A failed start while private (the child cannot even launch) is refused; privacy stays on and the owner hears
    /// "I can't listen privately right now." for every start that fails (#822 A: no silent state change).
    @Test func aFailedStartWhilePrivateKeepsPrivacyAndSaysSoEachTime() async throws {
        let rig = try await DuckRig(script: "/bin/cat <&3 >> control.txt &\n" + AmbientDuckReloadTests.entry,
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        _ = try await rig.confirmation()
        _ = try await receiveFrame(on: rig.socket, step: "privacy on audio")
        try await recipientSocketSend(audio(rig.stream, 1, final: true), on: rig.socket)
        #expect(await eventually { rig.details("ambient_ended").count == 1 })
        try FileManager.default.removeItem(at: rig.fake.config)
        for _ in 0..<2 {
            try await recipientSocketSend(audio(UUID(), 0), on: rig.socket)
            #expect(await eventually { rig.details("ambient_refused").count >= 1 })
            _ = try await receiveFrame(on: rig.socket, step: "refusal")
        }
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 3 })
        #expect(Array(rig.details("ambient_duck_confirmed").dropFirst()).sorted()
                == Array(repeating: "unavailable confirm=confirmprivacyunavailable/0:sent", count: 2))
        #expect(rig.env.router.duckMode(connection: connection))
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1"])
        await rig.env.router.settle()
        await rig.env.listener.stop(reason: "synthetic test complete")
    }

    /// Key 1 through the router: a reloaded start-private child that never starts is refused at the deadline,
    /// privacy stays on, and the owner is told once.
    @Test func aReloadThatNeverStartsKeepsPrivacy() async throws {
        let later = "/bin/cat > /dev/null"
        let rig = try await DuckRig(script: AmbientDuckReloadTests.staged(AmbientDuckReloadTests.entry, later),
                                    clips: AmbientDuckModeTests.clips, startDeadline: 0.3)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        #expect(await rig.env.router.reload() == .reloaded)
        #expect(await eventually { rig.details("ambient_ended").contains("privacy unconfirmedStart") })
        #expect(await eventually {
            rig.details("ambient_duck_confirmed").last == "unavailable confirm=confirmprivacyunavailable/0:sent"
        })
        #expect(rig.env.router.duckMode(connection: connection))
        await rig.finish()
    }
}
#endif
