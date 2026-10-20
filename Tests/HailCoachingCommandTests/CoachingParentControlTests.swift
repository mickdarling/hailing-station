import Darwin
import Foundation
import HailCore
import Testing
@testable import haild

/// `haild coaching --parent-control` (#645): the Mac app's pipes replace the terminal, and the only extra
/// output is a content-free end reason.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct CoachingParentControlTests {
    @Test func routeEndIsNamedAndLocalOffIsNot() async throws {
        let rig = try Rig()
        _ = try rig.command.control("enable aware")
        #expect(rig.command.owner.status == .active)
        try #require(rig.audio).session.invalidateRoute()
        #expect(rig.command.owner.endReason == .route)
        await rig.command.join()
        #expect(rig.command.owner.status == .off && rig.command.owner.endReason == .route)

        let local = try Rig()
        _ = try local.command.control("enable aware")
        _ = try local.command.control("off")
        await local.command.join()
        #expect(local.command.owner.endReason == nil)
    }

    @Test func nextEnableClearsThePreviousReason() async throws {
        let rig = try Rig()
        _ = try rig.command.control("enable aware")
        try #require(rig.audio).session.invalidateRoute()
        await rig.command.join()
        _ = try rig.command.control("enable aware")
        #expect(rig.command.owner.status == .active && rig.command.owner.endReason == nil)
        await rig.command.join()
    }

    @Test func statusAfterARouteEndCarriesOnlyTheReasonWord() async throws {
        let rig = try Rig()
        _ = try rig.command.control("enable aware")
        try #require(rig.audio).session.invalidateRoute()
        await rig.command.join()
        let input = try Pipe(), output = try Pipe()
        defer { output.closeRead() }
        let keyboard = try CoachingKeyboard(input: input.read, observeSignals: false, ended: { rig.command.off() })
        let terminal = try CoachingTerminal.parentPipe(output: output.write)
        input.send("status\nquit\n")
        try await CoachingCommand.interact(rig.command, keyboard: keyboard, terminal: terminal)
        input.closeWrite(); input.closeRead(); output.closeWrite()
        let lines = output.drain().split(separator: "\n").map(String.init)
        // The banner is ignored by the card's parser; only the two status words parse.
        #expect(lines.suffix(2) == ["coaching: off", "coaching ended: route"])
        #expect(lines.compactMap(PrivateCoachingStatusLine.init) == [.status(.off), .ended(.route)])
    }

    @Test func parentPipeIsNonblockingAndRefusesATerminal() throws {
        let pipe = try Pipe()
        defer { pipe.closeRead(); pipe.closeWrite() }
        let terminal = try CoachingTerminal.parentPipe(output: pipe.write)
        #expect(fcntl(pipe.write, F_GETFL) & O_NONBLOCK != 0)
        try terminal.write("coaching: off\n")
        terminal.close()
        var controller: Int32 = -1, endpoint: Int32 = -1
        try #require(openpty(&controller, &endpoint, nil, nil, nil) == 0)
        defer { Darwin.close(controller); Darwin.close(endpoint) }
        #expect(throws: CoachingCommandError.localControlRequired) { try CoachingTerminal.parentPipe(output: endpoint) }
    }

    @MainActor private final class Rig {
        @MainActor final class Holder { var audio: ExecutablePrivateAudio? }
        let holder = Holder()
        let command: CoachingCommand
        var audio: ExecutablePrivateAudio? { holder.audio }
        init() throws {
            let capture = ExecutableCoachingCapture(), player = ExecutablePrivatePlayer(), holder = holder
            command = try CoachingCommand(listener: "coach", transport: { _, _ in ParentTestTransport() },
                                          audio: { hooks in
                let audio = try ExecutablePrivateAudio(capture: capture, player: player, hooks: hooks)
                holder.audio = audio
                return CoachingCommandAudio(owner: audio, playback: { .idle })
            }, speech: ExecutableMockSpeech())
        }
    }

    @MainActor private final class ParentTestTransport: ForegroundCoachingTransport {
        func send(_ control: ForegroundCoachingControl) -> Bool { true }
        func write(_ buffer: AudioCaptureBuffer) -> Bool { true }
        func close() {}
        func stop() async {}
    }

    private struct Pipe {
        let read: Int32, write: Int32
        init() throws {
            var descriptors: [Int32] = [-1, -1]
            guard Darwin.pipe(&descriptors) == 0 else { throw CoachingCommandError.invalidControl }
            read = descriptors[0]; write = descriptors[1]
        }
        func send(_ text: String) {
            let bytes = Data(text.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(write, $0.baseAddress, $0.count) }
        }
        func drain() -> String {
            var data = Data(), buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(read, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return String(bytes: data, encoding: .utf8) ?? ""
        }
        func closeRead() { Darwin.close(read) }
        func closeWrite() { Darwin.close(write) }
    }
}
