#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Privacy mode (internally duck) across children (#735): a reloaded child is told privacy is on; one that cannot
/// take it (no `duck` v2) ends privacy rather than let the host claim it; a refused entry leaves no wish behind; the connection's end drops it.
/// Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckReloadTests {
    static let record = "/bin/cat <&3 >> control.txt &\n"
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

    /// The old child's line, the new child's carried line once it starts, then the new child's own replayed entry.
    @Test func aReloadedChildIsToldDuckModeIsOn() async throws {
        let rig = try await DuckRig(script: Self.record + Self.entry)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        #expect(await rig.env.router.reload() == .reloaded)
        let three = String(repeating: "{\"duck\":true}\n", count: 3)
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == three })
        await rig.finish()
    }

    /// A child without `duck` v2 (none, or a v1 that still transcribes) started during privacy mode ends it: no "on" is
    /// ever claimed for a child not in it.
    @Test(arguments: [nil, 1] as [Int?])
    func aReloadedChildWithoutVersionTwoIsRefusedAndPrivacyKept(_ version: Int?) async throws {
        let later = Self.silent(advertises: version != nil, version: version ?? 0)
        let rig = try await DuckRig(script: Self.staged(Self.entry, later),
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        #expect(await rig.env.router.reload() == .reloaded)
        // Round 4 (Mick): privacy stays on, the child is refused (its run ends), and nothing is written to it.
        #expect(await eventually { rig.details("ambient_ended").contains { $0.hasSuffix("failed") } })
        #expect(rig.env.router.duckMode(connection: connection))
        #expect(rig.details("ambient_privacy") == ["child=unsupported_version kept=true"])
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1"])
        #expect(rig.details("ambient_duck_device") == ["on=true device=sent"])
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n")
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
        // The new child, still starting, takes the entry. The retiring old child also counts if its own `started`
        // has not been read yet (#807 key 2's nit (b), tracked on #735), so 1 or 2: waiting on that read is a race.
        #expect((1...2).contains(rig.env.router.setDuck(true, connection: connection, reason: "voice")))
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
