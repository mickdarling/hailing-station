#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Duck mode across children (#735 H-2): a reloaded child is told duck mode is on; one that cannot take it ends duck
/// mode rather than let the host claim it; a refused entry leaves no wish behind; the connection's end drops it.
/// Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckReloadTests {
    static let record = "/bin/cat <&3 >> control.txt &\n"
    /// `started` (advertising `duck` or not) and `stopped` only: a child that hears nothing.
    static func silent(advertises: Bool, delay: Bool = false) -> String {
        let duck = advertises ? #" -e 's/"phase": "started"/"duck": {"version": 1}, "phase": "started"/'"# : ""
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
    static let entry = AmbientVoiceDuckTests.fixture(saying: "Rightyo, duck mode.", advertises: true)

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

    /// A child without `duck` started during duck mode ends it: no "on" is ever claimed for a child not in it.
    @Test func aReloadedChildWithoutDuckEndsDuckMode() async throws {
        let rig = try await DuckRig(script: Self.staged(Self.entry, Self.silent(advertises: false)),
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        #expect(await rig.env.router.reload() == .reloaded)
        #expect(await eventually { !rig.env.router.duckMode(connection: connection) })
        #expect(rig.details("ambient_duck_unsupported") == ["child=started_without_duck"])
        #expect(rig.details("ambient_duck").last?.hasPrefix("on=false reason=timeout") == true)
        let device = ["on=true device=sent", "on=false device=sent"]
        #expect(await eventually { rig.details("ambient_duck_device") == device })
        await rig.finish()
    }

    /// An entry no child took withdraws the wish from a child still starting, which then is never written duck mode.
    @Test func aRefusedEntryLeavesNoWishBehind() async throws {
        let rig = try await DuckRig(script: Self.staged(Self.silent(advertises: false),
                                                        Self.silent(advertises: true, delay: true)))
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        #expect(await rig.env.router.reload() == .reloaded)
        #expect(rig.env.router.setDuck(true, connection: connection, reason: "voice") == 0)
        #expect(!rig.env.router.duckMode(connection: connection))
        let directory = rig.fake.directory.path
        #expect(await eventually {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { $0.hasPrefix("started.") }.count == 2
        })
        try await Task.sleep(for: .milliseconds(300))
        #expect(try rig.fake.recorded("control.txt") == "")
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=0 refused=unsupported"])
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
        let on = AmbientStopConfirmation.duckOn, off = AmbientStopConfirmation.duckOff
        let notSent = AmbientStopConfirmation.notSent
        let check = { (command: VoiceDuckCommand, reported: Int, isOn: Bool, persona: String?, token: String) in
            let answer = AmbientRightyoRouter.duckConfirmation(command, reported: reported, on: isOn)
            #expect(answer.0 == persona && answer.1 == token)
        }
        check(.on, 1, true, on, "on=true")
        check(.on, 0, true, on, "on=true still_on")
        check(.on, 0, false, notSent, "on=true refused=unsupported")
        check(.off, 1, false, off, "on=false")
        check(.off, 0, false, nil, "on=false")
        check(.refused(entry: true), 0, false, notSent, "on=true refused=anonymous")
        check(.refused(entry: false), 0, true, notSent, "on=false refused=anonymous")
    }
}
#endif
