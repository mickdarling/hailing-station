import Darwin
import Foundation
import HailCore
import Testing
@testable import haild

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct CoachingTerminalTests {
    @Test func fullSyntheticTerminalRefusesFeedbackWithoutWaitingForDrain() throws {
        let fixture = try PTYFixture(), flags = fcntl(fixture.output, F_GETFL)
        let terminal = try CoachingTerminal(output: fixture.output)
        #expect(fcntl(fixture.output, F_GETFL) & O_NONBLOCK == flags & O_NONBLOCK)
        try fixture.fill()
        let began = ContinuousClock.now
        #expect(throws: CoachingCommandError.invalidControl) { try terminal.write("coaching: active\n") }
        #expect(began.duration(to: .now) < .milliseconds(250))
        terminal.close(); terminal.close()
        // Filling a Darwin PTY also sets an opaque kernel flag that F_SETFL cannot clear. Compare the
        // access/status modes affected by this owner, not that independently reproduced kernel flag.
        let modes = O_ACCMODE | O_NONBLOCK | O_APPEND | O_ASYNC
        #expect(fcntl(fixture.output, F_GETFL) & modes == flags & modes)
        #expect(throws: CoachingCommandError.invalidControl) { try terminal.write("coaching: off\n") }
    }

    @Test func backedUpFeedbackAndReadyEOFRetireSameForegroundOwnerWithoutDrain() async throws {
        let fixture = try PTYFixture(), terminal = try CoachingTerminal(output: fixture.output)
        try fixture.fill()
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw CoachingCommandError.invalidControl }
        defer { Darwin.close(descriptors[0]) }
        let capture = ExecutableCoachingCapture(), player = ExecutablePrivatePlayer()
        let child = TerminalTestTransport()
        let command = try CoachingCommand(listener: "coach", transport: { _, _ in child }, audio: { hooks in
            let audio = try ExecutablePrivateAudio(capture: capture, player: player, hooks: hooks)
            return CoachingCommandAudio(owner: audio, playback: { .idle })
        }, speech: ExecutableMockSpeech())
        let keyboard = try CoachingKeyboard(input: descriptors[0], observeSignals: false, ended: { command.off() })
        _ = try command.control("enable aware")
        Darwin.close(descriptors[1]) // Ready EOF; there is deliberately no independent terminal drain.
        await #expect(throws: CoachingCommandError.invalidControl) {
            try await CoachingCommand.interact(command, keyboard: keyboard, terminal: terminal)
        }
        #expect(keyboard.closed && command.owner.status == .off && capture.stops == 1 && child.stops == 1)
    }

    @Test func boundedSuccessfulFeedbackAndNonTerminalRefusal() throws {
        let fixture = try PTYFixture(), terminal = try CoachingTerminal(output: fixture.output)
        try terminal.write("coaching: off\n")
        #expect(throws: CoachingCommandError.invalidControl) { try terminal.write(String(repeating: "x", count: 513)) }
        #expect(throws: CoachingCommandError.invalidControl) { try terminal.write("private\0data") }
        terminal.close()
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw CoachingCommandError.invalidControl }
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }
        #expect(throws: CoachingCommandError.localControlRequired) {
            try CoachingTerminal(output: descriptors[1])
        }
    }

    private final class TerminalTestTransport: ForegroundCoachingTransport {
        var stops = 0
        func send(_ control: ForegroundCoachingControl) -> Bool { true }
        func write(_ buffer: AudioCaptureBuffer) -> Bool { true }
        func close() {}
        func stop() async { stops += 1 }
    }
    private final class PTYFixture {
        let input: Int32, output: Int32
        init() throws {
            var controller: Int32 = -1, endpoint: Int32 = -1
            guard openpty(&controller, &endpoint, nil, nil, nil) == 0 else {
                throw CoachingCommandError.invalidControl
            }
            input = controller; output = endpoint
        }
        deinit { Darwin.close(input); Darwin.close(output) }
        func fill() throws {
            let flags = fcntl(output, F_GETFL)
            _ = fcntl(output, F_SETFL, flags | O_NONBLOCK)
            defer { _ = fcntl(output, F_SETFL, flags) }
            let bytes = Data(repeating: 120, count: 8_192)
            for _ in 0..<128 {
                let count = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
                if count < 0, errno == EAGAIN { return }
                guard count > 0 else { throw CoachingCommandError.invalidControl }
            }
            throw CoachingCommandError.invalidControl
        }
    }
}
