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

    @Test func theOptionIsAddedOnlyWhenAsked() {
        let config = URL(fileURLWithPath: "/synthetic/config.json")
        let plain = RightyoChildProcess.arguments(session: "hail-test", config: config, replyControl: true)
        let quiet = RightyoChildProcess.arguments(session: "hail-test", config: config, replyControl: true,
                                                  startPrivate: true)
        #expect(!plain.contains("--start-private"))
        #expect(quiet == plain + ["--start-private"])
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
        #expect(!control.report(false, write: written.write))
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
        #expect(control.observe(started: Data(line.utf8), write: written.write) == .unconfirmed)
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
        await #expect(throws: RightyoChildError.privacyUnconfirmed) { _ = try await pipeline.run() }
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
}
#endif
