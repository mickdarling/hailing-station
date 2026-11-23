#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The test owns both readers. Neither writer can block while one reader deliberately leaves its pipe full.
private final class PrivacyPositionPipes {
    let audio = Pipe(), lines = Pipe()
    let worker = DispatchQueue(label: "synthetic.privacy.samples")
    let input: RightyoStdinWriter
    let control: RightyoControlWriter

    init() throws {
        let audioFD = audio.fileHandleForWriting.fileDescriptor
        let lineFD = lines.fileHandleForWriting.fileDescriptor
        let audioReader = audio.fileHandleForReading.fileDescriptor
        let lineReader = lines.fileHandleForReading.fileDescriptor
        for descriptor in [audioFD, lineFD, audioReader, lineReader] {
            try #require(fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0)
        }
        // Keep the Pipe handles for the test. Each writer takes ownership of its duplicate.
        let inputFD = dup(audioFD)
        try #require(inputFD >= 0)
        input = RightyoStdinWriter(input: inputFD, exit: RightyoExitLatch(), timing: .init(), writer: worker)
        let controlFD = dup(lineFD)
        try #require(controlFD >= 0)
        control = RightyoControlWriter(controlFD)
    }

    func fillControl() throws {
        let descriptor = lines.fileHandleForWriting.fileDescriptor
        var buffer = [UInt8](repeating: 32, count: 512)
        for size in [buffer.count, 1] {
            var count: Int
            repeat { count = Darwin.write(descriptor, &buffer, size) } while count > 0 || (count < 0 && errno == EINTR)
            let error = errno
            try #require(count == -1 && error == EAGAIN)
        }
    }

    func read(_ pipe: Pipe) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 1_024), result = Data()
        while true {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return result }
            try #require(count > 0)
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    deinit { input.close(abandon: true) }
}

@Suite struct RightyoPrivacyPositionTests {
    private func started(positioned: Bool, privateLaunch: Bool = false) -> Data {
        let capabilities = positioned ? #""duck_after_sample":1"# : ""
        let flag = privateLaunch ? #","private":true"# : ""
        return Data(#"{"duck":{"version":3\#(flag)},"capabilities":{\#(capabilities)}}"#.utf8)
    }

    @Test(arguments: [true, false])
    func offAfterWrittenSilenceAndQueuedPrivateSamples(positioned: Bool) throws {
        let pipes = try PrivacyPositionPipes()
        let scheduled = Mutex<(@Sendable () -> Void)?>(nil), host = Mutex<[Bool]>([])
        let clock = PrivacyRetryClock(now: { DispatchTime(uptimeNanoseconds: 1) },
                                      schedule: { _, work in scheduled.withLock { $0 = work } })
        let duck = AmbientDuckControl(clock: clock, setPrivate: { value in host.withLock { $0.append(value) } })
        let output = AmbientDuckControl.PositionedOutput(input: pipes.input, control: pipes.control)
        #expect(duck.observe(started: started(positioned: positioned), output: output, write: pipes.control.duck)
                == .kept)
        let pcm = Data([1, 2]), privatePCM = Data([3, 4, 5, 6]), publicPCM = Data([7, 8])
        let prefix = AmbientGapFill.chunkBytes
        #expect(pipes.input.write(pcm, leadingSilenceBytes: prefix))
        pipes.worker.sync {}
        try #require(duck.report(true, write: pipes.control.duck))
        try #require(duck.acknowledge() == .counted && duck.mayHearAudio)
        #expect(try pipes.read(pipes.lines) == Data("{\"duck\":true}\n".utf8))
        try pipes.fillControl()
        pipes.worker.suspend()
        #expect(pipes.input.write(privatePCM))
        #expect(!duck.report(false, write: pipes.control.duck))
        pipes.worker.resume()
        #expect(duck.active && duck.mayHearAudio && host.withLock { $0 } == [true])
        #expect(pipes.input.write(publicPCM))
        pipes.worker.sync {}
        var expected = Data(repeating: 0, count: prefix)
        expected.append(pcm); expected.append(privatePCM)
        let boundary = expected.count / 2
        expected.append(publicPCM)
        #expect(try pipes.read(pipes.audio) == expected)
        #expect(pipes.input.counters.writtenBytes == pcm.count + privatePCM.count + publicPCM.count)
        try retryOff(duck, pipes: pipes, positioned: positioned) {
            scheduled.withLock { work in
                defer { work = nil }
                return work
            }
        }
        let line = positioned ? "{\"duck\":false,\"after_sample\":\(boundary)}\n" : "{\"duck\":false}\n"
        #expect(try pipes.read(pipes.lines) == Data(line.utf8))
        #expect(!duck.active && host.withLock { $0 } == [true, false])
    }

    private func retryOff(_ duck: AmbientDuckControl, pipes: PrivacyPositionPipes, positioned: Bool,
                          take: () -> (@Sendable () -> Void)?) throws {
        let retry = take()
        retry?() // Still full. The next attempt must carry the original boundary.
        _ = try pipes.read(pipes.lines)
        if positioned {
            let deliver = try #require(take())
            deliver()
        } else {
            #expect(retry == nil)
            #expect(duck.report(false, write: pipes.control.duck))
        }
    }

    @Test(arguments: [true, false]) func privateStartupUsesWrittenSamplesUnlessSuperseded(newOn: Bool) throws {
        let pipes = try PrivacyPositionPipes(), duck = AmbientDuckControl(startPrivate: true)
        let output = AmbientDuckControl.PositionedOutput(input: pipes.input, control: pipes.control)
        #expect(duck.report(false, write: pipes.control.duck))
        #expect(duck.withAudioAdmission { allowed, _ in allowed && pipes.input.write(Data([1, 2])) })
        pipes.worker.sync {}
        pipes.worker.suspend()
        #expect(duck.withAudioAdmission { allowed, _ in allowed && pipes.input.write(Data([3, 4])) })
        if newOn { #expect(duck.report(true, write: pipes.control.duck)) }
        #expect(duck.observe(started: started(positioned: true, privateLaunch: true),
                             output: output, write: pipes.control.duck) == .kept)
        pipes.worker.resume()
        pipes.worker.sync {}
        #expect(try pipes.read(pipes.audio) == Data([1, 2, 3, 4]))
        let expected = newOn ? Data() : Data("{\"duck\":false,\"after_sample\":1}\n".utf8)
        #expect(try pipes.read(pipes.lines) == expected)
        #expect(duck.active == newOn)
    }

    @Test func failedOffKeepsHostPrivateAndStdinPublic() throws {
        let pipes = try PrivacyPositionPipes(), host = Mutex<[Bool]>([])
        let duck = AmbientDuckControl(startPrivate: true, setPrivate: { value in host.withLock { $0.append(value) } })
        let output = AmbientDuckControl.PositionedOutput(input: pipes.input, control: pipes.control)
        #expect(duck.observe(started: started(positioned: true, privateLaunch: true),
                             output: output, write: pipes.control.duck) == .kept)
        pipes.control.close()
        #expect(!duck.report(false, write: pipes.control.duck))
        #expect(duck.active && host.withLock { $0.isEmpty })
        let pcm = Data([1, 2])
        #expect(duck.withAudioAdmission { allowed, _ in allowed && pipes.input.write(pcm) })
        pipes.worker.sync {}
        #expect(try pipes.read(pipes.audio) == pcm)
    }

    @Test func oldAckAfterDeliveredOffCannotProveAnUnwrittenOn() throws {
        let pipes = try PrivacyPositionPipes(), duck = AmbientDuckControl()
        let output = AmbientDuckControl.PositionedOutput(input: pipes.input, control: pipes.control)
        #expect(duck.observe(started: started(positioned: true), output: output, write: pipes.control.duck) == .kept)
        #expect(duck.report(true, write: pipes.control.duck))
        #expect(duck.report(false, write: pipes.control.duck))
        try pipes.fillControl()
        #expect(!duck.report(true, write: pipes.control.duck))
        #expect(duck.acknowledge() == .counted)
        #expect(!duck.mayHearAudio && duck.settled == .refused(nil))
        #expect(!duck.withAudioAdmission { allowed, _ in allowed && pipes.input.write(Data([1, 2])) })
        pipes.worker.sync {}
        #expect(try pipes.read(pipes.audio).isEmpty)
    }
}
#endif
