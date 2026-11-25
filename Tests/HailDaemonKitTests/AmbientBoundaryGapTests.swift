#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryGapTests {
    typealias Rig = AmbientBoundaryRig

    /// Both writers get the same clock credit, accepted sequences and real preceding hole.
    @Test(arguments: [false, true]) func gapPrefix(queued: Bool) async throws {
        async let comparison = capture(queued: queued, withdraw: false)
        async let boundary = capture(queued: queued, withdraw: true)
        let (sent, withheld) = try await (comparison, boundary)
        let prefix = Rig.prefix + Rig.later + AmbientGapFillRig.silence(1)
        #expect(sent == AmbientGapFillRig.joined(prefix, Rig.marker, Rig.later))
        #expect(withheld == prefix + Rig.later)
    }

    private func capture(queued: Bool, withdraw: Bool) async throws -> Data {
        var heard = Data()
        try await Rig.withRig { rig in
            rig.start()
            rig.send(Rig.prefix, 0)
            rig.clock.advance(.seconds(1))
            if queued {
                rig.router.state.withLock { $0.reloading = true }
                defer { rig.router.state.withLock { $0.reloading = false } }
                rig.send(Rig.later, 1)
                if withdraw { try await rig.enter() }
                rig.send(Rig.marker, 3)
                if withdraw { rig.off() }
                rig.send(Rig.later, 4)
            } else {
                rig.send(Rig.later, 1)
                if withdraw {
                    try await rig.enter()
                    AmbientRightyoRouter.$beforePrivateHandoff.withValue({ rig.off() }, operation: {
                        rig.send(Rig.marker, 3)
                    })
                } else {
                    rig.send(Rig.marker, 3)
                }
                rig.send(Rig.later, 4)
            }
            heard = try await rig.end()
        }
        return heard
    }
}
#endif
