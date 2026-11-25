#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryUnsupportedTests {
    @Test func withdrawalBeforeCapabilityDecision() async throws {
        try await AmbientBoundaryRig.withRig { rig in
            rig.start()
            let first = try rig.active()
            try #require(await eventually { first.childStarted })
            try rewriteFake(rig.fake, """
                printf '%s\\n' "$@" > "$7.argv"
                IFS= read -r release <&3 || exit 1
                /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
                /bin/cat > "$7.raw"
                \(RightyoPrivacyLossRegressionTests.stopped)
                """)
            try #require(await rig.router.reload() == .reloaded)
            let child = try rig.active()
            try #require(!child.childStarted)
            try #require(rig.router.setDuck(true, connection: rig.connection, reason: "device") > 0)
            try rig.router.state.withLock { state in
                // The child's capability decision now needs this lock to read the current router wish.
                try #require(child.reportMedia(true))
                let bound = ContinuousClock.now + .seconds(10)
                while !child.childStarted && ContinuousClock.now < bound { sched_yield() }
                try #require(child.childStarted && !child.hearsAudio)
                _ = rig.router.changeDuck(false, connection: rig.connection, reason: "device", in: &state)
            }
            rig.send(AmbientBoundaryRig.later, 0)
            #expect(try await rig.end() == AmbientBoundaryRig.later)
            #expect(try !rig.arguments(child).contains("--start-private"))
            #expect(rig.events.list.withLock {
                $0.contains { $0.event == "ambient_ended" && $0.detail?.hasPrefix("delivered=0 ") == true }
            })
        }
    }
}
#endif
