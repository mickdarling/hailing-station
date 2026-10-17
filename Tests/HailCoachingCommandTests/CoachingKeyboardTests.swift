import Darwin
import Foundation
import Testing
@testable import haild

@Suite(.serialized) @MainActor struct CoachingKeyboardTests {
    @Test func syntheticPipeControlsAreBoundedAndReaderDoesNotBlockActor() async throws {
        let fixture = try PipeFixture(), ended = EndCount()
        let keyboard = try CoachingKeyboard(input: fixture.input, observeSignals: false, ended: { ended.value += 1 })
        try fixture.send("status\noff\n")
        var iterator = keyboard.lines.makeAsyncIterator()
        #expect(try await iterator.next() == "status")
        #expect(try await iterator.next() == "off")
        #expect(!keyboard.closed && ended.value == 0)
        keyboard.close(); keyboard.close()
        #expect(keyboard.closed && ended.value == 1)
    }
    @Test func EOFOrOverflowRetiresBeforeBufferedEnableCanBeConsumed() async throws {
        for overflow in [false, true] {
            let fixture = try PipeFixture(), ended = EndCount()
            let keyboard = try CoachingKeyboard(input: fixture.input, observeSignals: false,
                                                ended: { ended.value += 1 })
            try fixture.send(overflow ? "enable aware\nstatus\nstatus\nstatus\nstatus\n" : "enable aware\n")
            if !overflow { fixture.finish() }
            try await wait { keyboard.closed }
            #expect(keyboard.closed && ended.value == 1)
            var effects = 0
            do {
                for try await _ in keyboard.lines {
                    if keyboard.closed { break }; effects += 1
                }
            } catch { #expect(overflow) }
            #expect(effects == 0)
        }
    }
    @Test func oversizedNonASCIIPartialAndExplicitCloseFailClosed() async throws {
        for input in [String(repeating: "x", count: 97), "authored\u{01}", "partial-without-newline"] {
            let fixture = try PipeFixture(), ended = EndCount()
            let keyboard = try CoachingKeyboard(input: fixture.input, observeSignals: false,
                                                ended: { ended.value += 1 })
            try fixture.send(input); fixture.finish()
            try await wait { keyboard.closed }
            #expect(ended.value == 1)
            keyboard.close()
            #expect(ended.value == 1)
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
    private final class EndCount { var value = 0 }
    private final class PipeFixture {
        let input: Int32
        private var output: Int32?
        init() throws {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw CoachingCommandError.invalidControl }
            input = fds[0]; output = fds[1]
        }
        deinit { Darwin.close(input); if let output { Darwin.close(output) } }
        func send(_ string: String) throws {
            guard let output else { throw CoachingCommandError.invalidControl }
            let bytes = Data(string.utf8)
            let count = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
            guard count == bytes.count else { throw CoachingCommandError.invalidControl }
        }
        func finish() { if let output { Darwin.close(output); self.output = nil } }
    }
}
