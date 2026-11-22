#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Both child input descriptors append to one recording pipe. Byte positions give their actual write order.
final class RightyoRecordingChild {
    let worker = DispatchQueue(label: "synthetic.privacy.stdin")
    let input: RightyoStdinWriter
    let control: RightyoControlWriter
    let exit = RightyoExitLatch()
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
        control = RightyoControlWriter(ends[1])
        if !startPrivate { input.startedPublic() }
        worker.suspend()
    }

    func reserve(through sequence: Int? = nil) -> RightyoPrivacyOff {
        let epoch = input.reserve(through: sequence)
        return RightyoPrivacyOff { [input, control] expired in control.relax(input, epoch: epoch, expired: expired) }
    }

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

#endif
