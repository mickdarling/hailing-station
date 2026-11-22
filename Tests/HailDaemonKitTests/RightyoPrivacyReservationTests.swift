#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoPrivacyReservationTests {
    private let off = Data("{\"duck\":false}\n".utf8)

    @Test func aHeldAckCannotProveAnEntryRefusedAfterDeferredOff() throws {
        let child = try RightyoRecordingChild(startPrivate: false)
        let duck = AmbientDuckControl()
        let tighten: (Bool) -> Bool = { [control = child.control, input = child.input] _ in control.tighten(input) }
        #expect(duck.observe(started: AmbientPrivacyAckGateTests.started, write: tighten) == .kept)
        try #require(duck.report(true, write: tighten))
        let firstOn = Data("{\"duck\":true}\n".utf8)
        #expect(try child.recorded() == firstOn)
        while child.control.media(true) {}
        while child.control.write(" ") {}
        let change = child.reserve()
        #expect(duck.relax(expired: false) { change.attempt(false) } == .pending)
        #expect(try child.take(off.count) == Data("{\"media\":true}\n".utf8))
        try #require(duck.relax(expired: false) { change.attempt(false) } == .delivered)
        #expect(!duck.report(true, write: tighten))
        #expect(duck.acknowledge() == .counted)
        #expect(!duck.mayHearAudio && duck.settled == .refused(nil))
        #expect(try child.recorded().suffix(off.count) == off)
        try #require(duck.report(true, write: tighten))
        #expect(!duck.mayHearAudio)
        #expect(duck.acknowledge() == .counted && duck.mayHearAudio)
        #expect(try child.recorded() == firstOn)
    }

    @Test func aLateStartupDecisionCannotReleaseANewerEntry() {
        let duck = AmbientDuckControl()
        let written = AmbientDuckControlTests.Written()
        #expect(duck.report(true, write: written.write))
        #expect(duck.observe(started: Data(AmbientDuckControlTests.started.utf8), write: written.write) == .refused)
        #expect(!duck.report(true, write: written.write))
        var resumed = false
        duck.release { resumed = true }
        #expect(!resumed && !duck.mayHearAudio)
        #expect(!duck.report(false, write: written.write))
        #expect(duck.mayHearAudio && written.all.isEmpty)
    }

    @Test(arguments: [nil, 7] as [Int?], [false, true])
    func redundantPublicOffLeavesStdinRunning(cutoff: Int?, expireBeforeDrain: Bool) throws {
        let audio = Pipe(), child = try RightyoRecordingChild(startPrivate: false, audioPipe: audio)
        let reader = audio.fileHandleForReading.fileDescriptor
        try #require(fcntl(reader, F_SETFL, O_NONBLOCK) == 0)
        while child.control.media(true) {}
        let prefix = Data([1, 2]), suffix = Data([3, 4]), late = Data([5, 6])
        #expect(child.input.write(prefix, admission: 5))
        let change = child.reserve(through: cutoff)
        #expect(change.attempt(false) == .pending)
        #expect(child.input.write(suffix, admission: 8))
        if expireBeforeDrain { #expect(change.attempt(true) == .failed) }
        child.release()
        #expect(try RightyoRecordingChild.available(reader) == prefix + suffix)
        if !expireBeforeDrain { #expect(change.attempt(true) == .failed) }
        #expect(child.input.write(late, admission: 7))
        child.release()
        #expect(try RightyoRecordingChild.available(reader) == late)
        #expect(child.input.counters.droppedBytes == 0)
        #expect(try child.recorded().range(of: off) == nil)
        withExtendedLifetime(audio) {}
    }

    @Test(arguments: [false, true])
    func directlyLaunchedChildOrdersInputOnlyWhenPrivate(startPrivate: Bool) async throws {
        let fake = try FakeRightyo("/bin/cat > audio.raw\n/bin/cat <&3 > control.txt")
        defer { fake.cleanUp() }
        let child = try RightyoChildProcess(executable: fake.executable, config: fake.config, session: "demo",
                                           replyControl: true, startPrivate: startPrivate)
        while child.reportMedia(true) {}
        let epoch = child.input.reserve(through: 7)
        #expect(child.control.relax(child.input, epoch: epoch, expired: false) == .pending)
        #expect(child.control.relax(child.input, epoch: epoch, expired: true) == .failed)
        let pcm = Data([1, 2])
        #expect(child.input.write(pcm, admission: 7))
        #expect(await child.stop(eofGrace: 20, termGrace: 20) == .exited(0))
        let recorded = try Data(contentsOf: fake.directory.appendingPathComponent("audio.raw"))
        #expect(recorded == (startPrivate ? Data() : pcm))
        #expect(try !fake.recorded("control.txt").contains("{\"duck\":false}"))
    }

    @Test(arguments: [false, true])
    func finalWriteSerializesWithRetirement(exit: Bool) throws {
        let atWrite = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let child = try RightyoRecordingChild {
            atWrite.signal()
            proceed.wait()
        }
        let change = child.reserve()
        let delivery = DispatchQueue(label: "synthetic.privacy.delivery")
        delivery.async {
            #expect(change.attempt(false) == .delivered)
            atWrite.signal()
        }
        atWrite.wait()
        // Try the exact lock that retirement needs while the syscall is held at its last instruction boundary.
        let available = exit ? child.exit.observationAvailable
            : child.input.state.withLockIfAvailable { _ in true } != nil
        #expect(!available)
        if !available { proceed.signal() }
        if exit { child.exit.signal(.exited(0)) } else { child.input.close(abandon: true) }
        // A write outside the lock would still be held here, with the control reader open.
        let atRetirement = try? child.recorded()
        if available { proceed.signal() }
        delivery.sync {}
        #expect(atRetirement == off)
        #expect(change.attempt(false) == .failed)
    }
}
#endif
