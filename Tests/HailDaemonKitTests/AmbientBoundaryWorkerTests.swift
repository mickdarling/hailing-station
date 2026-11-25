#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryWorkerTests {
    @Test func occupiedWorker() async throws {
        let duringSpawn = Mutex<(@Sendable () -> Void)?>(nil)
        let atSpawn: @Sendable (UUID) -> Void = { _ in
            let work = duringSpawn.withLock { action in
                defer { action = nil }
                return action
            }
            work?()
        }
        try await AmbientBoundaryRig.withRig(childMade: atSpawn) { rig in
            let router = rig.router, earlier = UUID()
            duringSpawn.withLock { action in
                action = {
                    #expect(router.state.withLock { $0.working && !$0.reloading })
                    router.ambientAudio(.ended(stream: earlier, reason: .superseded))
                    router.ambientPrivacyPreArm(connection: rig.connection)
                    #expect(router.duckMode(connection: rig.connection))
                    rig.start()
                    for sequence in 0..<3 { rig.send(AmbientBoundaryRig.marker, sequence) }
                    #expect(router.state.withLock { $0.queue.count == 5 && $0.active == nil })
                    rig.off()
                    rig.send(AmbientBoundaryRig.later, 3)
                }
            }
            // Put the earlier start on the real worker. Its pre-registration callback runs after this slot opens.
            router.state.withLock { $0.reloading = true }
            rig.start(earlier, on: UUID())
            router.state.withLock { $0.reloading = false }
            try #require(await eventually { router.activeStream == rig.stream })
            let child = try rig.active()
            #expect(try await rig.end() == AmbientBoundaryRig.later)
            #expect(try !rig.arguments(child).contains("--start-private"))
        }
    }
}
#endif
