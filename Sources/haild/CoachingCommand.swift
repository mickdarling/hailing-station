import Darwin
import Foundation
import HailCore

struct CoachingCommandAudio {
    let owner: any ForegroundCoachingAudio
    let playback: () -> CoachingPlaybackObservation
}

/// These controls are exclusively owner-local keyboard input, never child output or conversation text.
@MainActor final class CoachingCommand {
    @MainActor private final class Activity {
        var ownerAnswering = true
        var playback: (() -> CoachingPlaybackObservation)?
        func flags() -> CoachingActivityFlags? {
            guard let observation = playback?(), observation != .unavailable else { return nil }
            return CoachingActivityFlags(ownerMidAnswer: ownerAnswering, playback: observation == .pending)
        }
    }
    private let activity = Activity()
    let owner: ForegroundCoaching

    init(listener: String, transport: @escaping (ForegroundCoaching.ChildHooks,
         @escaping () -> CoachingActivityFlags?) throws -> any ForegroundCoachingTransport,
         audio: @escaping (PrivateCoachingSession.Hooks) throws -> CoachingCommandAudio,
         speech: any ForegroundCoachingSpeech, clock: CoachingClock = .init()) throws {
        let activity = self.activity
        owner = try ForegroundCoaching(listenerID: listener, transport: { hooks in
            try transport(hooks, { activity.flags() })
        }, audio: { hooks in
            let resource = try audio(hooks)
            activity.playback = resource.playback
            return resource.owner
        }, speech: speech, clock: clock)
    }

    /// Returns false only for explicit quit; invalid local input retires the owner and throws.
    func control(_ line: String) throws -> Bool {
        do { return try apply(line) } catch { off(); throw error }
    }
    private func apply(_ line: String) throws -> Bool {
        switch line {
        case "status": return true
        case "enable aware":
            activity.ownerAnswering = true // Every new run needs a separate trusted idle observation.
            try owner.enable(participantAwareness: true)
        case "owner answering": activity.ownerAnswering = true; owner.interruptSpeech()
        case "owner idle":
            guard owner.status == .active else { throw CoachingCommandError.invalidControl }
            activity.ownerAnswering = false
        case "off", "awareness lost", "permission lost": off()
        case "quit": off(); return false
        default: off(); throw CoachingCommandError.invalidControl
        }
        return true
    }

    func off() { activity.ownerAnswering = true; owner.off() }
    func join() async {
        off()
        while owner.status != .off {
            // An interrupted caller still joins its owned retirement, without a cancelled-task busy loop.
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
    }

    /// Native factory is compiled, not exercised by synthetic tests. No factory runs before explicit local opt-in.
    static func native(_ configuration: CoachingConfiguration,
                       rendererEnvironment: [String: String]? = nil) throws -> CoachingCommand {
        let profile = try configuration.loadProfile()
        return try CoachingCommand(listener: configuration.listenerID, transport: { hooks, flags in
            try CoachingChildTransport(configuration.childConfiguration(profile: profile, provenance: .liveMicrophone),
                                       hooks: hooks, activityFlags: flags)
        }, audio: { hooks in
            let privateAudio = try ApplePrivateCoaching(privateOutputDeviceID: configuration.privateOutput,
                roomMicrophoneDeviceID: configuration.roomMicrophone,
                listenerID: configuration.listenerID, hooks: hooks)
            return CoachingCommandAudio(owner: privateAudio, playback: { privateAudio.privatePlaybackObservation() })
        }, speech: CoachingSpeechRenderer.local(outputRoot: configuration.outputRoot,
                                                environment: rendererEnvironment
                                                    ?? ProcessInfo.processInfo.environment))
    }

    @MainActor static func run(_ arguments: [String]) async throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
            throw CoachingCommandError.localControlRequired
        }
        let configuration = try CoachingConfiguration.parse(arguments)
        let command = try native(configuration)
        let terminal = try CoachingTerminal()
        let keyboard = try CoachingKeyboard(ended: { command.off() })
        try await interact(command, keyboard: keyboard, terminal: terminal)
    }

    /// Shared run loop for native composition and authored-only control/feedback regressions.
    static func interact(_ command: CoachingCommand, keyboard: CoachingKeyboard,
                         terminal: CoachingTerminal) async throws {
        defer { terminal.close() }
        var failure: (any Error)?
        do {
            try terminal.write("""
            Private coaching is OFF. Local controls only:
            enable aware | owner idle | owner answering | status | off | awareness lost | permission lost | quit
            Enable confirms participant awareness; private output and separate room microphone must qualify.

            """)
            for try await line in keyboard.lines {
                guard !keyboard.closed else { break } // EOF/overflow cannot replay buffered enable controls.
                guard try command.control(line) else { break }
                try terminal.write("coaching: \(command.owner.status)\n")
            }
        } catch { failure = CoachingCommandError.invalidControl }
        keyboard.close()
        await command.join()
        if let failure { throw failure }
    }
}
