#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

private final class ManualDeadline: Sendable {
    typealias Action = @Sendable () -> Void
    private let action = Mutex<Action?>(nil)
    func schedule(_ action: @escaping Action) { self.action.withLock { $0 = action } }
    func take() -> Action? {
        action.withLock { current in
            defer { current = nil }
            return current
        }
    }
    func fire() { take()?() }
}

/// Both child input descriptors append to one recording pipe. Byte positions give their actual write order.
private final class RecordingChild {
    let worker = DispatchQueue(label: "synthetic.privacy.stdin")
    let input: RightyoStdinWriter
    let control: RightyoControlWriter
    let deadline = ManualDeadline(), exit = RightyoExitLatch()
    private let readEnd: Int32
    private var held = true

    init(startPrivate: Bool = true, audioPipe: Pipe? = nil) throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        readEnd = ends[0]
        let inputEnd = dup(audioPipe?.fileHandleForWriting.fileDescriptor ?? ends[1])
        guard inputEnd >= 0, fcntl(readEnd, F_SETFL, O_NONBLOCK) == 0,
              [inputEnd, ends[1]].allSatisfy({ descriptor in
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 && fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0
              }) else {
            for descriptor in ends + [inputEnd] where descriptor >= 0 { Darwin.close(descriptor) }
            throw POSIXError(.EIO)
        }
        input = RightyoStdinWriter(input: inputEnd, exit: exit, timing: .init(backlogBytes: 2_097_152, backlogAge: 60),
                                   writer: worker)
        control = RightyoControlWriter(ends[1], startPrivate: startPrivate) { [deadline] in deadline.schedule($0) }
        worker.suspend()
    }

    func duck(_ on: Bool) -> Bool { control.duck(on, after: input) }

    func release() {
        if held { held = false; worker.resume() }
        worker.sync {}
    }

    func recorded() throws -> Data { try Self.available(readEnd) }

    static func available(_ descriptor: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 256)
        var result = Data()
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            if count == 0 || (count < 0 && errno == EAGAIN) { return result }
            try #require(count > 0)
            result.append(contentsOf: bytes.prefix(count))
        }
    }

    deinit {
        control.close()
        input.close(abandon: true)
        release()
        Darwin.close(readEnd)
    }
}

@Suite(.timeLimit(.minutes(1))) struct RightyoPrivacyOrderingTests {
    private let first = Data([1, 2]), second = Data([3, 4]), later = Data([5, 6])
    private let off = Data("{\"duck\":false}\n".utf8), on = Data("{\"duck\":true}\n".utf8)

    @Test func drainedPrefixPrecedesOffAndLaterPCM() throws {
        let child = try RecordingChild(startPrivate: false)
        #expect(child.duck(true))
        #expect(try child.recorded() == on)
        #expect(child.input.write(first))
        #expect(child.input.write(second))
        #expect(child.duck(false))
        #expect(child.input.write(later))
        #expect(try child.recorded().isEmpty)
        child.release()
        child.deadline.fire()
        #expect(try child.recorded() == first + second + off + later)
        #expect(child.input.counters.droppedBytes == 0)
    }

    @Test func deadlineDiscardsOnlyPreBoundaryAudio() throws {
        let child = try RecordingChild()
        #expect(child.input.write(first, leadingSilenceBytes: AmbientGapFill.chunkBytes))
        #expect(child.input.write(second))
        #expect(child.duck(false))
        #expect(child.input.write(later))
        child.deadline.fire()
        #expect(try child.recorded() == off)
        child.release()
        #expect(try child.recorded() == later)
        #expect(child.input.counters.droppedBytes == first.count + second.count)
    }

    @Test func deadlineRetiresTheUnwrittenSuffixOfAnInFlightChunk() throws {
        let audio = Pipe(), pcm = Data(repeating: 7, count: 2_097_152)
        let child = try RecordingChild(audioPipe: audio)
        let reader = audio.fileHandleForReading.fileDescriptor
        try #require(fcntl(reader, F_SETFL, O_NONBLOCK) == 0)
        child.release()
        try #require(child.input.write(pcm))
        var ready = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
        try #require(poll(&ready, 1, 5_000) == 1)
        try #require(child.duck(false))
        #expect(try child.recorded().isEmpty)
        child.deadline.fire()
        #expect(try child.recorded() == off)
        let written = child.input.counters.writtenBytes
        try #require(written > 0 && written < pcm.count)
        #expect(try RecordingChild.available(reader) == Data(pcm.prefix(written)))
        #expect(child.input.write(later))
        child.release()
        let alignment = Data(repeating: 0, count: written % 2)
        #expect(try RecordingChild.available(reader) == alignment + later)
        #expect(child.input.counters.droppedBytes == pcm.count - written)
        withExtendedLifetime(audio) {}
    }

    @Test func tighteningIsImmediateAndSupersedesDelayedOff() throws {
        let child = try RecordingChild()
        #expect(child.input.write(first))
        #expect(child.duck(false))
        #expect(child.duck(true))
        #expect(try child.recorded() == on)
        child.deadline.fire()
        child.release()
        #expect(try child.recorded() == first)
    }

    @Test func supersededDeadlineCannotDiscardAcrossANewerBoundary() throws {
        let child = try RecordingChild()
        #expect(child.input.write(first))
        #expect(child.duck(false))
        let stale = try #require(child.deadline.take())
        #expect(child.duck(true))
        #expect(child.input.write(second))
        #expect(child.duck(false))
        stale()
        #expect(try child.recorded() == on)
        child.release()
        #expect(try child.recorded() == first + second + off)
    }

    @Test(arguments: [true, false], [true, false])
    func exitOrInputClosureDropsPendingOff(childExits: Bool, deadlineFirst: Bool) throws {
        let child = try RecordingChild()
        #expect(child.input.write(first))
        #expect(child.duck(false))
        if childExits { child.exit.signal(.exited(0)) } else { child.input.close(abandon: false) }
        let replacement = try RecordingChild(startPrivate: false)
        #expect(replacement.input.write(later))
        if deadlineFirst { child.deadline.fire() }
        child.release()
        child.deadline.fire()
        replacement.release()
        let retired = try child.recorded()
        #expect(retired.isEmpty || retired == first)
        #expect(try replacement.recorded() == later)
    }

    @Test func publicPCMStaysFIFOAndPublicControlsStayImmediate() throws {
        let child = try RecordingChild(startPrivate: false)
        #expect(child.input.write(first))
        #expect(child.duck(false))
        #expect(child.control.media(true))
        #expect(child.input.write(second))
        #expect(try child.recorded() == off + Data("{\"media\":true}\n".utf8))
        child.deadline.fire()
        child.release()
        #expect(try child.recorded() == first + second)
    }
}
#endif
