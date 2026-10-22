#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Privacy mode (internally duck) across children (#735): a reloaded child starts private (S-2b); one that does not
/// confirm it is killed, never admitted; a refused entry leaves no wish behind; the connection's end drops it.
/// Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckReloadTests {
    static let record = "/bin/cat <&3 >> control.txt &\n"
    /// Each launch's arguments after the executable, one line per launch.
    static let argv = "echo \"$*\" >> argv.txt\n"
    /// `started` (advertising `duck` at `version`, v2 by default, or not at all) and `stopped` only: a child that
    /// hears nothing.
    static func silent(advertises: Bool, version: Int = 2, delay: Bool = false) -> String {
        let duck = advertises
            ? #" -e 's/"phase": "started"/"duck": {"version": \#(version)}, "phase": "started"/'"# : ""
        return """
        \(delay ? "/bin/sleep 1" : ":")
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g"\(duck)
        /usr/bin/touch started.$$
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """
    }
    /// `first` on the first launch, `later` on every launch after it (a reload).
    static func staged(_ first: String, _ later: String) -> String {
        record + "if [ -f first.done ]; then\n\(later)\nelse\n/usr/bin/touch first.done\n\(first)\nfi"
    }
    static let entry = AmbientPrivacyEntryTests.fixture(saying: "Rightyo, stop recording.", advertises: true)

    /// While private (#735 S-2b) a reloaded child is launched start-private and, once its `started` confirms it, is
    /// written nothing more for it: the old child's line, then only the new child's own replayed entry.
    @Test func aReloadedChildStartsPrivate() async throws {
        let rig = try await DuckRig(script: Self.record + Self.argv + Self.entry)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        #expect(await rig.env.router.reload() == .reloaded)
        let two = String(repeating: "{\"duck\":true}\n", count: 2)
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == two })
        let launches = try rig.fake.recorded("argv.txt").split(separator: "\n")
        #expect(launches.count == 2)
        #expect(launches.first?.hasSuffix("--control-fd 3") == true)
        #expect(launches.last?.hasSuffix("--control-fd 3 --start-private") == true)
        #expect(rig.details("ambient_privacy_start").isEmpty)
        await rig.finish()
    }

    /// A child asked to start private whose `started` does not confirm it (no `duck`, a v1, or a v2 that does not say
    /// `private`) is killed and never admitted (#735 S-2b): privacy stays on, and the device never hears it end.
    @Test(arguments: [nil, 1, 2] as [Int?]) func aReloadedChildThatDoesNotConfirmPrivacyIsKilled(
        _ version: Int?
    ) async throws {
        let later = "echo $$ > later.pid\n" + Self.silent(advertises: version != nil, version: version ?? 0)
        let rig = try await DuckRig(script: Self.staged(Self.entry, later),
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        #expect(await rig.env.router.reload() == .reloaded)
        #expect(await eventually { rig.details("ambient_privacy_start") == ["outcome=refused reason=unconfirmed"] })
        #expect(await eventually { rig.details("ambient_ended").contains("privacy unconfirmedStart") })
        #expect(rig.env.router.duckMode(connection: connection))
        #expect(rig.details("ambient_duck_unsupported").isEmpty)
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1"])
        #expect(await eventually { rig.details("ambient_duck_device") == ["on=true device=sent"] })
        let pid = try #require(Int32(rig.fake.recorded("later.pid").trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { kill(pid, 0) != 0 })
        await rig.finish()
    }

    /// An entry no child took withdraws the wish from a child still starting, which then is never written duck mode.
    /// Round 4: an entry while a reloaded child is between spawn and `started` is taken by that child: a v2 child is
    /// written `{"duck":true}` once it starts; any other is refused there, privacy kept.
    @Test(arguments: [2, 1]) func anEntryWhileTheChildStartsIsDecidedAtStarted(_ version: Int) async throws {
        let rig = try await DuckRig(script: Self.staged(Self.silent(advertises: false),
                                                        Self.silent(advertises: true, version: version, delay: true)))
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        #expect(await rig.env.router.reload() == .reloaded)
        #expect(rig.env.router.setDuck(true, connection: connection, reason: "voice") == 1)
        #expect(rig.env.router.duckMode(connection: connection))
        if version >= 2 {
            #expect(await eventually { (try? rig.fake.recorded("control.txt")) == "{\"duck\":true}\n" })
        } else {
            #expect(await eventually { rig.details("ambient_privacy") == ["child=unsupported_version kept=true"] })
            #expect(try rig.fake.recorded("control.txt") == "")
        }
        #expect(rig.env.router.duckMode(connection: connection))
        await rig.finish()
    }

    /// The connection's end cancels the auto-end and drops duck mode: no timeout fires for a connection that is gone.
    @Test func theConnectionsEndDropsDuckModeAndItsTimeout() async throws {
        let rig = try await DuckRig(script: Self.record + Self.entry, timeout: 1)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        #expect(rig.env.router.duckMode(connection: connection))
        rig.socket.cancel(with: .normalClosure, reason: nil)
        #expect(await eventually { !rig.env.router.duckMode(connection: connection) })
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1"])
        await rig.env.router.settle()
        await rig.env.listener.stop(reason: "synthetic test complete")
    }

    @Test func eachAnswerHasItsClipAndToken() {
        let on = AmbientStopConfirmation.privacyOn, off = AmbientStopConfirmation.privacyOff
        let notSent = AmbientStopConfirmation.notSent, status = AmbientStopConfirmation.privacyStatus
        let check = { (command: PrivacyCommand, reported: Int, isOn: Bool, persona: String?, token: String) in
            let answer = AmbientRightyoRouter.duckConfirmation(command, reported: reported, on: isOn)
            #expect(answer.0 == persona && answer.1 == token)
        }
        check(.enter, 1, true, on, "on=true")
        check(.enter, 0, true, on, "on=true still_on")
        check(.enter, 0, false, notSent, "on=true refused=unsupported_version")
        check(.exit, 1, false, off, "on=false")
        check(.exit, 0, false, nil, "on=false")
        check(.status, 0, true, status, "status on=true")
        check(.status, 0, false, nil, "status on=false")
        check(.stillRecording, 0, false, AmbientStopConfirmation.stillRecording, "negated")
        check(.refused, 0, false, nil, "refused=not_owner")
        check(.unverified, 0, false, AmbientStopConfirmation.privacyRefused, "refused=unverified_owner")
        check(.unavailable, 0, true, AmbientStopConfirmation.privacyUnavailable, "unavailable")
        check(.hint, 0, false, AmbientStopConfirmation.privacyHint, "hint")
    }
}
#endif
