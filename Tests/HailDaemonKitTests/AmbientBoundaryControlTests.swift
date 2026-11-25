#if os(macOS)
import Darwin
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryControlTests {
    /// Stdin acknowledges the public sample before the control reader can drain another byte.
    @Test func independentDescriptors() async throws {
        let record = """
            IFS= read -r entry <&3 || exit 1
            [ "$entry" = '{"duck":true}' ] || exit 1
            \(AmbientBoundaryRig.acknowledge)
            /bin/dd bs=2 count=1 of=receipt.tmp 2>/dev/null && /bin/mv receipt.tmp receipt
            /bin/cat > "$7.raw"
            """
        try await AmbientBoundaryRig.withRig(script: AmbientBoundaryRig.child(record: record)) { rig in
            rig.start()
            try await rig.enter()
            let child = try rig.active()
            try fill(child)
            rig.off()
            rig.send(AmbientBoundaryRig.later, 0)
            let receipt = rig.fake.directory.appendingPathComponent("receipt")
            try #require(await eventually { FileManager.default.fileExists(atPath: receipt.path) })
            #expect(try Data(contentsOf: receipt) == AmbientBoundaryRig.later)
            try fill(child)
            await rig.router.mediaNotices.queued {}.value
            let clips = rig.router.state.withLock { AmbientRightyoRouter.clipChain(rig.connection, in: &$0) }
            await clips.queued {}.value
            let confirmation = "on=false reason=device confirm=unreported"
            #expect(rig.events.list.withLock { $0.contains { $0.event == "ambient_duck_confirmed"
                && $0.detail == confirmation } })
            #expect(!rig.router.duckMode(connection: rig.connection))
            #expect(await !rig.env.listener.replyHold.holds(rig.connection))
            let frames = try await AmbientPrivacySwitchTests.untilPong(rig.pair.sockets[0], step: "notice")
            #expect(frames.contains(.control(.duckMode(on: false, reason: "device"))))
            _ = try await rig.end()
        }
    }

    private func fill(_ child: RightyoAmbientPipeline) throws {
        while true {
            errno = 0
            let written = child.reportMedia(true)
            let error = errno
            if written || error == EINTR { continue }
            try #require(error == EAGAIN)
            return
        }
    }
}
#endif
