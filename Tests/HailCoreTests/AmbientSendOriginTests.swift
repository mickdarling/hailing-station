import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailCore

@Suite struct AmbientSendOriginTests {
    @Test func defaultQueueSendsExactlyItsOriginalPayloadsInOrder() async throws {
        let rig = try await SendOriginRig.ready()
        let queue = AmbientAudioSendQueue(maxPending: 10, send: { try await rig.connection.sendAudio($0) },
                                          onFailure: { _, _ in Issue.record("unexpected failure") })
        let stream = UUID()
        let payloads = [0, 1, 3].map { ambientSegment(stream: stream, sequence: $0) }
        for payload in payloads { await queue.enqueue(payload) }
        await queue.waitUntilIdle()
        #expect(try await audioFrames(rig.socket).map(\.payload) == payloads.map { .audio($0) })
        #expect(await queue.failure == nil)
        await rig.connection.disconnect()
    }

    @Test func staleCaptureEpochRejectsQueuedAndAlreadyInFlightSends() async throws {
        let rig = try await SendOriginRig.ready()
        let epoch = Mutex<UInt64>(0)
        let admission = AmbientSendAdmission { epoch.withLock { $0 == 0 } }
        let gate = SleepGate()
        let queue = AmbientAudioSendQueue(maxPending: 10, send: { audio in
            try await gate.sleep(.zero)
            try await rig.connection.sendAudio(audio)
        }, onFailure: { _, error in
            #expect(error as? HostConnectionFailure == .notReady)
        }, admission: admission)
        let stream = UUID()
        await queue.enqueue(ambientSegment(stream: stream))
        try await waitUntil { await gate.isWaiting() }
        await queue.enqueue(ambientSegment(stream: stream, sequence: 1))
        epoch.withLock { $0 += 1 }
        await gate.fire()
        await queue.waitUntilIdle()
        #expect(await queue.failure as? HostConnectionFailure == .notReady)
        #expect(try await audioFrames(rig.socket).isEmpty)
        #expect(AmbientSendAdmission.isCurrent)
        await rig.connection.disconnect()
    }
}
