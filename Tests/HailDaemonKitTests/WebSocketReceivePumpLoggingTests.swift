import Dispatch
import Foundation
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    @Test func blockedDropLoggerCannotDelayCloseAndCoalescesRemainingDrops() async throws {
        let entered = SelectionPreflightSignal<Void>()
        let release = DispatchSemaphore(value: 0)
        let rig = PumpRig(onDrop: { _, _ in
            entered.finish(.success(()))
            release.wait()
        })
        let park = PumpAudioPark()
        let stream = UUID()
        defer { release.signal(); release.signal(); park.release.finish(.success(())); rig.pump.stop() }
        rig.start { _ in await park.wait() }
        rig.transport.deliver(.application(try pumpMarker(1)))
        try await park.entered.wait("logging dispatch parked")
        let worker = try #require(rig.pump.worker)
        for sequence in 1...31 { rig.transport.deliver(.application(try pumpAudio(stream, sequence))) }
        try await entered.wait("logger acknowledged block")
        for sequence in 32...40 { rig.transport.deliver(.application(try pumpAudio(stream, sequence))) }
        #expect(rig.transport.outstanding == 1)
        #expect(rig.pump.droppedAudioCount == 10)
        rig.transport.deliver(.terminal("peer closed"))
        #expect(try await rig.ended.wait("close with logger blocked") == "peer closed")
        #expect(rig.lifecycle.isRetired)
        #expect(rig.drops.count == 1)
        release.signal()
        release.signal()
        await rig.pump.waitForDropLogging()
        #expect(rig.drops.count == 10)
        #expect(rig.drops.ranges == [1...1, 2...10])
        park.release.finish(.success(()))
        await worker.value
    }
}
