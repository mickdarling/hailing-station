#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #904 ask 3 step 0: a fresh connection must inherit host safety modes before automatic restore can rely on
/// admission. Real loopback listener and fake RightyO; all device claims and PCM are synthetic.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientReconnectHostAdmissionTests {
    /// #904 fix round 1 step 0: re-assert privacy before opening any stream, with no live or parked privacy.
    /// Stop before sending PCM if the host cannot confirm this no-stream request.
    @Test func freshConnectionPrivacyReassertionConfirmsBeforeResume() async throws {
        let rig = try await RestoreRig(phrase: nil, holdSpawn: 1)
        defer { rig.close() }
        let (socket, connection) = try await rig.connect(capabilities: [DuckMode.capability])
        #expect(rig.router.activeStream == nil && rig.parked == nil)
        try await AmbientPrivacySwitchTests.send(true, on: socket)
        // The notice can follow pongs while the router's notice task chain waits.
        try await AmbientPrivacyPreArmTests.until(.duckMode(on: true, reason: "device"), on: socket,
                                                step: "no-stream privacy re-assert")
        #expect(rig.router.activeStream == nil, "privacy re-assert must not start capture")
        try #require(rig.router.duckMode(connection: connection), "privacy must be held before resume")
        try await recipientSocketSend(RestoreRig.segment(UUID(), 0, fill: 0x11, resume: true), on: socket)
        #expect(await eventually { rig.router.activeConnection() == connection }, "resume start processed")
        #expect(await eventually {
            (try? rig.fake.recorded("argv.1.txt"))?.contains("--start-private") == true
        }, "resume child starts private")
        #expect(rig.router.activePipeline?.hearsAudio == false, "PCM held until private started")
        try rig.release()
        #expect(await eventually { rig.router.activePipeline?.hearsAudio == true }, "private started confirmed")
        await rig.finish()
        #expect(!rig.heard(1).contains(0x11), "no pre-confirmation PCM reaches RightyO")
    }

    /// Privacy held before a drop reaches the fresh stream on the new connection, a normal or a resume start (#941).
    /// The peer's step-0 test expected 0 PCM bytes at RightyO. By #735 S-1 and S-8 a child that confirmed it is private
    /// hears audio, in RAM only, to catch the exit phrase, so this pins what privacy promises instead: (a) no byte
    /// before the child's private `started` reaches RightyO, (b) no words or reply leave it (here and in
    /// `AmbientPrivacyParkWordsTests`), and (c) at most the one segment sent after that `started` does.
    @Test(arguments: [false, true])
    func privacyHeldAcrossNewConnectionNeverReachesRightyo(resume: Bool) async throws {
        let rig = try await RestoreRig(phrase: "stop recording", holdSpawn: 2)
        defer { rig.close() }
        let (first, dropped) = try await rig.start()
        try #require(await eventually { rig.router.duckMode(connection: dropped) }, "first connection holds privacy")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty }, "privacy entry settled")
        await rig.drop(first, dropped)
        let (socket, connection) = try await rig.start(resume: resume, fill: 0x11)
        #expect(connection != dropped, "reconnect must have a new session identity")
        #expect(rig.router.duckMode(connection: connection), "privacy must transfer or admission must refuse")
        // The fresh child's `started` is held: everything sent until it is released comes before its private proof.
        let stream = try #require(rig.router.activeStream)
        #expect(rig.router.activePipeline?.hearsAudio == false)
        for sequence in 1...3 {
            try await recipientSocketSend(RestoreRig.segment(stream, sequence, fill: 0x11), on: socket)
        }
        try await barrier(on: socket, step: "audio before the private started processed")
        try rig.release()
        #expect(await eventually { rig.router.activePipeline?.hearsAudio == true }, "private started confirmed")
        try await recipientSocketSend(RestoreRig.segment(stream, 4, fill: 0x22), on: socket)
        try await barrier(on: socket, step: "audio after the private started processed")
        await rig.finish()
        let heard = rig.heard(2)
        #expect(!heard.contains(0x11), "(a) no PCM from before the private started reaches RightyO")
        #expect(heard.count <= AmbientPrivacyParkTests.segmentBytes, "(c) at most the one segment after it")
        #expect(await rig.env.rig.adapter.contexts.isEmpty, "(b) no request leaves the private child")
        #expect(rig.details("ambient_ended").allSatisfy { $0.contains("delivered=0") }, "(b) nothing delivered")
        #expect((try? rig.fake.recorded("argv.2.txt"))?.contains("--start-private") == true)
    }

    @Test(arguments: [false, true])
    func parkedMeetingTransfersAtFirstAmbientStart(resume: Bool) async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let meetingID = try await AmbientModeRestoreTests.meetingDropped(rig)
        let (socket, connection) = try await rig.start(resume: resume)
        #expect(await eventually { rig.control(2) == RestoreRig.gate }, "first child control is the gate")
        #expect(try await rig.confirmation(on: socket) == RestoreRig.resumed.text)
        #expect(rig.router.meetingMode(connection: connection) && rig.parked == nil)
        #expect(rig.router.state.withLock { $0.meeting[connection]?.meetingID } == meetingID)
        await rig.finish()
    }

    @Test(arguments: [false, true])
    func parkedMediaTransfersAtFirstAmbientStart(resume: Bool) async throws {
        let rig = try await RestoreRig(phrase: "media mode")
        defer { rig.close() }
        let (first, dropped) = try await rig.start()
        #expect(await eventually { rig.router.mediaMode(connection: dropped) }, "first connection holds media")
        await rig.drop(first, dropped)
        #expect(rig.parked?.media != nil)
        let (socket, connection) = try await rig.start(resume: resume)
        #expect(await eventually { rig.control(2) == RestoreRig.gate }, "first child control is the gate")
        #expect(rig.router.mediaMode(connection: connection) && rig.parked == nil)
        try await barrier(on: socket, step: "fresh media stream processed")
        await rig.finish()
    }
}
#endif
