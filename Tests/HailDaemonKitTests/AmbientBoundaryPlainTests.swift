#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryPlainTests {
    @Test(arguments: [false, true]) func plainControlLine(queued: Bool) async throws {
        try await AmbientBoundaryRig.withRig(script: AmbientBoundaryRig.child(positioned: false)) { rig in
            rig.start()
            try await rig.enter()
            let child = try rig.active()
            rig.send(AmbientBoundaryRig.prefix, 0)
            if queued {
                rig.router.state.withLock { $0.reloading = true }
                rig.send(AmbientBoundaryRig.marker, 1)
            }
            rig.off()
            rig.router.state.withLock { $0.reloading = false }
            rig.send(AmbientBoundaryRig.later, queued ? 2 : 1)
            #expect(try await rig.end() == AmbientBoundaryRig.prefix + AmbientBoundaryRig.later)
            #expect(try rig.controls(child) == "{\"duck\":true}\n{\"duck\":false}\n")
        }
    }
}
#endif
