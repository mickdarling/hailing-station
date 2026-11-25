#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryHandoffTests {
    @Test func positionedHandoff() async throws {
        try await AmbientBoundaryRig.withRig { rig in
            rig.start()
            try await rig.enter()
            let child = try rig.active()
            rig.send(AmbientBoundaryRig.prefix, 0)
            AmbientRightyoRouter.$beforePrivateHandoff.withValue({ rig.off() }, operation: {
                rig.send(AmbientBoundaryRig.marker, 1)
            })
            rig.send(AmbientBoundaryRig.later, 2)
            let heard = try await rig.end()
            #expect(try rig.controls(child) == "{\"duck\":true}\n{\"duck\":false,\"after_sample\":1}\n")
            #expect(heard == AmbientBoundaryRig.prefix + AmbientBoundaryRig.later)
        }
    }
}
#endif
