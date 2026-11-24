#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

extension RestoreRig {
    /// Drops a device's connection, as a lost network does, and waits for its teardown.
    func drop(_ socket: URLSessionWebSocketTask, _ connection: UUID) async {
        enum Mode: Sendable { case duck, meeting, media }
        let (listener, router) = (env.listener, router)
        @Sendable func heldModes() -> Set<Mode> {
            router.state.withLock { state in
                var held = Set<Mode>()
                if state.duck[connection] != nil { held.insert(.duck) }
                if state.meeting[connection] != nil { held.insert(.meeting) }
                if state.media[connection] != nil { held.insert(.media) }
                return held
            }
        }
        let before = heldModes()
        socket.cancel(with: .goingAway, reason: nil)
        #expect(await eventually { await !Self.connections(of: listener).contains(connection) }, "restore drop marker")
        #expect(await eventually { router.state.withLock { $0.latest[connection] == nil } },
                "restore teardown marker")
        #expect(await eventually { before.isDisjoint(with: heldModes()) }, "teardown cleared the previously held modes")
        #expect(await eventually { heldModes().isEmpty }, "dropped connection holds no modes")
    }
}
#endif
