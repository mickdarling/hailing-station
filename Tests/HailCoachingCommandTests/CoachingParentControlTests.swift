import Darwin
import Foundation
import HailCore
import Testing
@testable import haild

/// `haild coaching --parent-control` (#645): the verified Mac app's socket replaces the terminal, and the only
/// extra output is a content-free end reason.
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
        let channel = try Channel()
        defer { channel.closeApp() }
        let keyboard = try CoachingKeyboard(input: channel.haild, observeSignals: false,
                                            ended: { rig.command.off() })
        let terminal = try CoachingTerminal.parentSocket(socket: channel.haild)
        channel.send("status\nquit\n")
        try await CoachingCommand.interact(rig.command, keyboard: keyboard, terminal: terminal)
        channel.closeHaild()
        let lines = channel.drain().split(separator: "\n").map(String.init)
        // The banner is ignored by the card's parser; only the two status words parse.
        #expect(lines.suffix(2) == ["coaching: off", "coaching ended: route"])
        #expect(lines.compactMap(PrivateCoachingStatusLine.init) == [.status(.off), .ended(.route)])
    }

    @Test func statusGoesBackOverTheSocketAndPipesOrTerminalsAreRefused() throws {
        let channel = try Channel()
        defer { channel.closeApp() }
        let terminal = try CoachingTerminal.parentSocket(socket: channel.haild)
        #expect(fcntl(channel.haild, F_GETFL) & O_NONBLOCK != 0)
        try terminal.write("coaching: off\n")
        terminal.close(); channel.closeHaild()
        #expect(channel.drain() == "coaching: off\n")
        var descriptors: [Int32] = [-1, -1]
        try #require(pipe(&descriptors) == 0)
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }
        #expect(throws: CoachingCommandError.localControlRequired) {
            try CoachingTerminal.parentSocket(socket: descriptors[1])
        }
        var controller: Int32 = -1, endpoint: Int32 = -1
        try #require(openpty(&controller, &endpoint, nil, nil, nil) == 0)
        defer { Darwin.close(controller); Darwin.close(endpoint) }
        #expect(throws: CoachingCommandError.localControlRequired) {
            try CoachingTerminal.parentSocket(socket: endpoint)
        }
    }

    @Test func parentControlIsRefusedBeforeAnyConfigurationIsRead() async {
        // Test stdin is never a socket from a pinned app, so even unparseable arguments fail on the parent check,
        // with the gate's own error (exit 77), not the configuration refusal (64).
        await #expect(throws: CoachingParentRefusal.unverified) {
            try await CoachingCommand.run(["--parent-control", "--not-a-flag"])
        }
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

    /// A socketpair as the Mac app makes it: one end for the app, one for haild's stdin.
    private struct Channel {
        let app: Int32, haild: Int32
        init() throws {
            var descriptors: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw CoachingCommandError.invalidControl
            }
            app = descriptors[0]; haild = descriptors[1]
        }
        func send(_ text: String) {
            let bytes = Data(text.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(app, $0.baseAddress, $0.count) }
        }
        /// Reads what haild already wrote, without waiting for EOF: the keyboard's own copy of the socket closes
        /// later on the main queue, which this main-actor test must not block.
        func drain() -> String {
            var data = Data(), buffer = [UInt8](repeating: 0, count: 256)
            _ = fcntl(app, F_SETFL, fcntl(app, F_GETFL) | O_NONBLOCK)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(app, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return String(bytes: data, encoding: .utf8) ?? ""
        }
        func closeApp() { Darwin.close(app) }
        func closeHaild() { Darwin.close(haild) }
    }
}
