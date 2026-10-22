#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Duck mode's spoken status and auto-end warning (#735 H-4), through the listener. "Are you still listening" is
/// answered by the host with `confirm-duck-on/` and nothing is dispatched; about a minute before the auto-end the
/// owner hears `confirm-duck-ending/`, once per arming, never after duck mode ended. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckStatusWarningTests {
    static let duckOn = AmbientAckClip(pcm: Data(repeating: 9, count: 480), sampleRate: 24_000,
                                       text: "Duck mode is on.")
    static let ending = AmbientAckClip(pcm: Data(repeating: 4, count: 480), sampleRate: 24_000,
                                       text: "Duck mode ends in a minute.")
    static let clips = AmbientAckLibrary(clips: ["confirmduckon": [duckOn], "confirmduckending": [ending]])

    @Test func theStatusCueIsAnsweredByTheHostAndDispatchesNothing() async throws {
        let script = try AmbientDuckCueWiringTests.script(["A synthetic thought.", "Are you still listening?"])
        let rig = try await DuckRig(script: script, clips: Self.clips)
        defer { rig.close() }
        #expect(try await Self.words(rig) == "Duck mode is on.")
        #expect(try await Self.words(rig) == "Duck mode is on.")
        #expect(await eventually { rig.details("ambient_duck_cue").count == 1 })
        await rig.finish()
        #expect(rig.details("ambient_duck_cue") == ["cue=status outcome=answered confirm=confirmduckon/0:sent"])
        // The agent never answers it: nothing reached the session.
        #expect(await rig.env.rig.adapter.contexts.isEmpty)
    }

    @Test func theWarningPlaysOnceBeforeTheAutoEnd() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, clips: Self.clips,
                                    timeout: 1.2, lead: 0.6)
        defer { rig.close() }
        #expect(try await Self.words(rig) == "Duck mode is on.")
        #expect(try await Self.words(rig) == "Duck mode ends in a minute.")
        let connection = try #require(rig.connection())
        // The warning comes first, while duck mode is still on.
        #expect(rig.env.router.duckMode(connection: connection))
        #expect(await eventually { rig.details("ambient_duck").count == 2 })
        await rig.finish()
        #expect(rig.details("ambient_duck_ending") == ["confirm=confirmduckending/0:sent"])
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1",
                                                "on=false reason=timeout reported=1"])
    }

    /// An exit before the warning cancels it with the auto-end.
    @Test func noWarningOnceDuckModeEndedEarlier() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, clips: Self.clips,
                                    timeout: 1.0, lead: 0.5)
        defer { rig.close() }
        #expect(try await Self.words(rig) == "Duck mode is on.")
        let connection = try #require(rig.connection())
        #expect(rig.env.router.setDuck(false, connection: connection, reason: "voice") == 1)
        try await Task.sleep(for: .seconds(1.2))
        await rig.finish()
        #expect(rig.details("ambient_duck_ending").isEmpty)
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=voice reported=1"])
    }

    /// A re-entry re-arms the warning with the timer: the first arming's warning never plays, the new one does once.
    @Test func aReentryRearmsTheWarning() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, clips: Self.clips,
                                    timeout: 2.0, lead: 1.0)
        defer { rig.close() }
        #expect(try await Self.words(rig) == "Duck mode is on.")
        let connection = try #require(rig.connection())
        try await Task.sleep(for: .seconds(0.5))
        #expect(rig.env.router.setDuck(true, connection: connection, reason: "voice") == 1)
        #expect(await eventually { rig.details("ambient_duck").count == 3 })
        await rig.finish()
        #expect(rig.details("ambient_duck_ending") == ["confirm=confirmduckending/0:sent"])
        #expect(rig.details("ambient_duck").last == "on=false reason=timeout reported=1")
    }

    /// A timeout under twice the lead has no warning; without clips the warning plays nothing and says so.
    @Test func aShortTimeoutHasNoWarningAndAnUnrecordedFolderPlaysNothing() async throws {
        // Under twice the lead: no warning is armed at all.
        let short = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, timeout: 0.9, lead: 0.5)
        defer { short.close() }
        #expect(await eventually { short.details("ambient_duck").count == 2 })
        await short.finish()
        #expect(short.details("ambient_duck_ending").isEmpty)

        let silent = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, timeout: 0.8, lead: 0.4)
        defer { silent.close() }
        #expect(await eventually { silent.details("ambient_duck").count == 2 })
        await silent.finish()
        #expect(silent.details("ambient_duck_ending") == ["confirm=no_clips"])
    }

    /// The words of the next text frame, skipping the clip audio that follows each one.
    static func words(_ rig: DuckRig) async throws -> String? {
        for _ in 0..<8 {
            let frame = try await receiveFrame(on: rig.socket, step: "duck confirmation words")
            if case .text(let words) = frame.payload { return words.text }
        }
        return nil
    }

    /// Armed at exactly twice the lead; the late skip needs half the lead left when the warning comes due.
    @Test func theWarningIsArmedFromTwiceTheLeadAndSkippedWhenLate() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, timeout: 30, lead: 15)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        #expect(rig.env.router.duckTimer(connection: connection)?.warning != nil)
        await rig.finish()
        typealias Router = AmbientRightyoRouter
        let end = Date(timeIntervalSince1970: 1_000)
        #expect(Router.duckWarningDue(deadline: end, now: end.addingTimeInterval(-60), lead: 60))
        #expect(Router.duckWarningDue(deadline: end, now: end.addingTimeInterval(-30), lead: 60))
        #expect(!Router.duckWarningDue(deadline: end, now: end.addingTimeInterval(-29), lead: 60))
        #expect(!Router.duckWarningDue(deadline: end, now: end.addingTimeInterval(5), lead: 60)) // woke past the end
    }

    /// M09: the warning comes due after the connection's child has ended (duck mode itself still on): no warning.
    @Test func noWarningWithoutARunningChild() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, clips: Self.clips,
                                    timeout: 1.6, lead: 0.8)
        defer { rig.close() }
        #expect(try await Self.words(rig) == "Duck mode is on.")
        let connection = try #require(rig.connection())
        try await recipientSocketSend(audio(rig.stream, 1, final: true), on: rig.socket)
        await rig.env.router.settle()
        #expect(rig.env.router.liveRuns == 0)
        #expect(rig.env.router.duckMode(connection: connection))
        try await Task.sleep(for: .seconds(1.2))
        #expect(rig.details("ambient_duck_ending").isEmpty)
        await rig.env.listener.stop(reason: "synthetic test complete")
    }

    /// M08: `duckArmed` holds only for the current arming's token, never a stale one.
    @Test func onlyTheCurrentArmingCounts() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, timeout: 30, lead: 10)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection()), router = rig.env.router
        let first = try #require(router.duckTimer(connection: connection))
        #expect(router.duckArmed(connection: connection, token: first.token))
        #expect(!router.duckArmed(connection: connection, token: UUID()))
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        #expect(!router.duckArmed(connection: connection, token: first.token)) // re-armed: the first is stale
        #expect(first.warning?.isCancelled == true)
        await rig.finish()
    }

    /// M10c: the connection's end cancels the warning task itself, not only the state it would check.
    @Test func theConnectionsEndCancelsTheWarning() async throws {
        let rig = try await DuckRig(saying: "Rightyo, duck mode.", advertises: true, timeout: 30, lead: 10)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        let timer = try #require(rig.env.router.duckTimer(connection: connection))
        let warning = try #require(timer.warning)
        rig.env.router.stop(connection: connection)
        #expect(warning.isCancelled && timer.timer.isCancelled)
        await rig.finish()
    }

    @Test func cancellingTheTimerCancelsItsWarning() async {
        let timer = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let warning = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        AmbientDuckTimer(token: UUID(), timer: timer, warning: warning).cancel()
        #expect(timer.isCancelled && warning.isCancelled)
    }
}
#endif
