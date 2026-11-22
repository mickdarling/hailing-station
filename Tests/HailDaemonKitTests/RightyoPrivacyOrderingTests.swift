#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1))) struct RightyoPrivacyOrderingTests {
    private let first = Data([1, 2]), second = Data([3, 4]), later = Data([5, 6])
    private let off = Data("{\"duck\":false}\n".utf8), on = Data("{\"duck\":true}\n".utf8)

    @Test func drainedPrefixPrecedesOffAndLaterPCM() throws {
        let child = try RightyoRecordingChild(startPrivate: false)
        #expect(child.control.tighten(child.input))
        #expect(try child.recorded() == on)
        #expect(child.input.write(first))
        #expect(child.input.write(second))
        let change = child.reserve()
        #expect(child.input.write(later))
        #expect(try child.recorded().isEmpty)
        child.release()
        #expect(change.attempt(false) == .delivered)
        child.release()
        #expect(try child.recorded() == first + second + off + later)
        #expect(child.input.counters.droppedBytes == 0)
    }

    @Test func deadlineDiscardsOnlyPreBoundaryAudio() throws {
        let child = try RightyoRecordingChild()
        #expect(child.input.write(first, leadingSilenceBytes: AmbientGapFill.chunkBytes))
        #expect(child.input.write(second))
        let change = child.reserve()
        #expect(child.input.write(later))
        #expect(change.attempt(true) == .delivered)
        #expect(try child.recorded() == off)
        child.release()
        #expect(try child.recorded() == later)
        #expect(child.input.counters.droppedBytes == first.count + second.count)
    }

    @Test func deadlineRetiresTheUnwrittenSuffixOfAnInFlightChunk() throws {
        let audio = Pipe(), pcm = Data(repeating: 7, count: 2_097_152)
        let child = try RightyoRecordingChild(audioPipe: audio)
        let reader = audio.fileHandleForReading.fileDescriptor
        try #require(fcntl(reader, F_SETFL, O_NONBLOCK) == 0)
        child.release()
        try #require(child.input.write(pcm))
        var ready = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
        try #require(poll(&ready, 1, 5_000) == 1)
        let change = child.reserve()
        #expect(change.attempt(false) == .pending)
        #expect(try child.recorded().isEmpty)
        #expect(change.attempt(true) == .delivered)
        #expect(try child.recorded() == off)
        let written = child.input.counters.writtenBytes
        try #require(written > 0 && written < pcm.count)
        #expect(try RightyoRecordingChild.available(reader) == Data(pcm.prefix(written)))
        #expect(child.input.write(later))
        child.release()
        let alignment = Data(repeating: 0, count: written % 2)
        #expect(try RightyoRecordingChild.available(reader) == alignment + later)
        #expect(child.input.counters.droppedBytes == pcm.count - written)
        withExtendedLifetime(audio) {}
    }

    @Test func tighteningIsImmediateAndSupersedesDelayedOff() throws {
        let child = try RightyoRecordingChild()
        #expect(child.input.write(first))
        let change = child.reserve()
        #expect(child.control.tighten(child.input))
        #expect(try child.recorded() == on)
        #expect(change.attempt(true) == .failed)
        child.release()
        #expect(try child.recorded() == first)
    }

    @Test func supersededDeadlineCannotDiscardAcrossANewerBoundary() throws {
        let child = try RightyoRecordingChild()
        #expect(child.input.write(first))
        let stale = child.reserve()
        #expect(child.control.tighten(child.input))
        #expect(child.input.write(second))
        let latest = child.reserve()
        #expect(stale.attempt(true) == .failed)
        #expect(try child.recorded() == on)
        child.release()
        #expect(latest.attempt(false) == .delivered)
        #expect(try child.recorded() == first + second + off)
    }

    @Test(arguments: [true, false], [true, false])
    func exitOrInputClosureDropsPendingOff(childExits: Bool, deadlineFirst: Bool) throws {
        let child = try RightyoRecordingChild()
        #expect(child.input.write(first))
        let change = child.reserve()
        #expect(change.attempt(false) == .pending)
        if childExits { child.exit.signal(.exited(0)) } else { child.input.close(abandon: false) }
        let replacement = try RightyoRecordingChild(startPrivate: false)
        #expect(replacement.input.write(later))
        if deadlineFirst { #expect(change.attempt(true) == .failed) }
        child.release()
        #expect(change.attempt(true) == .failed)
        replacement.release()
        let retired = try child.recorded()
        #expect(retired.isEmpty || retired == first)
        #expect(try replacement.recorded() == later)
    }

    @Test func publicPCMStaysFIFOAndPublicControlsStayImmediate() throws {
        let child = try RightyoRecordingChild(startPrivate: false)
        #expect(child.input.write(first))
        #expect(child.reserve().attempt(false) == .delivered)
        #expect(child.control.media(true))
        #expect(child.input.write(second))
        #expect(try child.recorded() == off + Data("{\"media\":true}\n".utf8))
        child.release()
        #expect(try child.recorded() == first + second)
    }
}

extension RightyoPrivacyOrderingTests {
    @Test func aPublicLaunchWithAPendingPrivacyWishOrdersTheQueuedPrefix() throws {
        let child = try RightyoRecordingChild(startPrivate: false)
        #expect(child.input.write(first))
        let epoch = child.input.reserve(through: nil, privacyWanted: true)
        #expect(child.input.write(later))
        #expect(child.control.relax(child.input, epoch: epoch, expired: false) == .pending)
        #expect(try child.recorded().isEmpty)
        child.release()
        #expect(child.control.relax(child.input, epoch: epoch, expired: false) == .delivered)
        child.release()
        #expect(try child.recorded() == first + off + later)
    }

    @Test func idleReservationStopsANewDrain() throws {
        let child = try RightyoRecordingChild()
        child.release()
        let change = child.reserve()
        #expect(child.input.write(later))
        child.release()
        #expect(try child.recorded().isEmpty)
        #expect(change.attempt(false) == .delivered)
        child.release()
        #expect(try child.recorded() == off + later)
    }

    @Test(arguments: [false, true])
    func admissionSurvivesLateHandoff(expired: Bool) throws {
        let child = try RightyoRecordingChild()
        let change = child.reserve(through: 12)
        #expect(change.attempt(false) == .pending)
        if expired { #expect(change.attempt(true) == .delivered) }
        #expect(child.input.write(first, admission: 12))
        child.release()
        if !expired { #expect(change.attempt(false) == .delivered) }
        #expect(child.input.write(later, admission: 13))
        child.release()
        let expected = expired ? off + later : first + off + later
        #expect(try child.recorded() == expected)
    }

    @Test(arguments: [true, false])
    func retirementAfterIdleReservationRejectsDeliveryWithAnOpenReader(exit: Bool) throws {
        let child = try RightyoRecordingChild()
        let change = child.reserve()
        if exit { child.exit.signal(.exited(0)) } else { child.input.close(abandon: true) }
        #expect(change.attempt(false) == .failed)
        #expect(try child.recorded().isEmpty)
    }

    @Test func freeingControlCapacityDeliversExactlyOnceOnRetry() throws {
        let child = try RightyoRecordingChild()
        while child.control.media(true) {}
        let change = child.reserve()
        #expect(change.attempt(false) == .pending)
        let filled = try child.recorded()
        #expect(!filled.isEmpty && filled.range(of: off) == nil)
        #expect(change.attempt(false) == .delivered)
        #expect(change.attempt(true) == .failed)
        #expect(try child.recorded() == off)
    }
}
#endif
