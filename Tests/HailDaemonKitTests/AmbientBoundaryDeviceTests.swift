#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryDeviceTests {
    typealias Rig = AmbientBoundaryRig

    @Test func reentryGatesTheNextSegment() async throws {
        let record = """
            IFS= read -r first <&3 && [ "$first" = '{"duck":true}' ] || exit 1
            \(Rig.acknowledge)
            /bin/cat > "$7.raw"
            /bin/cat <&3 > "$7.control"
            """
        try await Rig.withRig(script: Rig.child(record: record)) { rig in
            rig.start()
            try await rig.enter()
            let child = try rig.active()
            rig.off()
            rig.router.ambientPrivacy(true, connection: rig.connection)
            #expect(rig.router.duckMode(connection: rig.connection) && !child.hearsAudio)
            rig.send(Rig.marker, 0)
            #expect(try await rig.end().isEmpty)
            #expect(try rig.controls(child) == "{\"duck\":false,\"after_sample\":0}\n{\"duck\":true}\n")
        }
    }

    @Test func lateStartedAndReplyRelease() async throws {
        let script = Rig.child(beforeStarted: "IFS= read -r release <&3 || exit 1")
        try await Rig.withRig(script: script) { rig in
            rig.router.ambientPrivacyPreArm(connection: rig.connection)
            rig.start()
            let child = try rig.active()
            try #require(await rig.env.listener.replyHold.holds(rig.connection))
            rig.off()
            await rig.router.mediaNotices.queued {}.value
            #expect(await !rig.env.listener.replyHold.holds(rig.connection))
            #expect(!child.childStarted)
            try #require(child.reportMedia(true))
            try #require(await eventually { child.childStarted && !child.privacyControl.active })
            #expect(!rig.router.duckMode(connection: rig.connection))
            rig.send(Rig.later, 0)
            #expect(try await rig.end() == Rig.later)
            #expect(try rig.controls(child) == "{\"duck\":false,\"after_sample\":0}\n")
        }
    }

    @Test func disconnectAfterOff() async throws {
        try await Rig.withRig { rig in
            rig.start()
            try await rig.enter()
            rig.off()
            rig.router.stop(connection: rig.connection)
            #expect(rig.router.state.withLock { $0.parks.isEmpty && !$0.parkOverflow })
            #expect(rig.router.modeSnapshot(connection: UUID()).contains(.duckMode(on: false)))
        }
    }

    @Test func repeatedSwitchKeepsTheFirstPosition() async throws {
        try await Rig.withRig { rig in
            rig.start()
            try await rig.enter()
            let child = try rig.active()
            rig.send(Rig.prefix, 0)
            rig.off()
            rig.send(Rig.later, 1)
            rig.off()
            #expect(try await rig.end() == Rig.prefix + Rig.later)
            #expect(try rig.controls(child) == "{\"duck\":true}\n{\"duck\":false,\"after_sample\":1}\n")
        }
    }
}
#endif
