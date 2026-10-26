#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #904 ask 3 step 0: a fresh connection must inherit host safety modes before automatic restore can rely on
/// admission. Real loopback listener and fake RightyO; all device claims and PCM are synthetic.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientReconnectHostAdmissionTests {
    @Test(arguments: [false, true])
    func privacyHeldAcrossNewConnectionNeverReachesRightyo(resume: Bool) async throws {
        let rig = try await RestoreRig(phrase: "stop recording")
        defer { rig.close() }
        let (first, dropped) = try await rig.start()
        try #require(await eventually { rig.router.duckMode(connection: dropped) }, "first connection holds privacy")
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty }, "privacy entry settled")
        await rig.drop(first, dropped)
        let (socket, connection) = try await rig.start(resume: resume)
        #expect(connection != dropped, "reconnect must have a new session identity")
        #expect(rig.router.duckMode(connection: connection), "privacy must transfer or admission must refuse")
        #expect(await eventually { rig.router.activePipeline?.hearsAudio == true }, "fresh child started")
        // Send after the child is ready, so absence cannot be a startup-buffering artifact. The initial packet and
        // this one contain only synthetic zeros. EOF and settle make the byte count deterministic.
        let stream = try #require(rig.router.activeStream)
        try await recipientSocketSend(audio(stream, 1), on: socket)
        try await barrier(on: socket, step: "fresh privacy stream audio processed")
        await rig.finish()
        let heard = (try? Data(contentsOf: rig.fake.directory.appendingPathComponent("audio.2.raw"))) ?? Data()
        // A confirmed-private child hears the stream in RAM only (#735 S-1, S-8: to hear the way back in); what must
        // never reach RightyO is audio before that proof. The first segment came before the child's private `started`
        // and is dropped, so at most the one sent after it is heard. On main the child is public and hears both.
        #expect(heard.count <= AmbientPrivacyParkTests.segmentBytes, "no PCM reaches RightyO before its private proof")
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
