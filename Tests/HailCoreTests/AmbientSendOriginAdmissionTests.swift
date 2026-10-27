import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailCore

@Suite struct AmbientSendOriginAdmissionTests {
    @Test func retirementDuringSuccessfulSendDropsAllPendingAudio() async throws {
        let rig = try await SendOriginRig.ready()
        let accepting = Mutex(true)
        let failures = Mutex(0)
        let admission = AmbientSendAdmission { accepting.withLock { $0 } }
        let queue = AmbientAudioSendQueue(maxPending: 10, send: { try await rig.connection.sendAudio($0) },
                                         onFailure: { _, _ in failures.withLock { $0 += 1 } }, admission: admission)
        let stream = UUID()
        await rig.socket.holdSends()
        await queue.enqueue(ambientSegment(stream: stream))
        try await waitUntil { try await audioFrames(rig.socket).count == 1 }
        await queue.enqueue(ambientSegment(stream: stream, sequence: 1))
        await queue.enqueue(ambientSegment(stream: stream, sequence: 2))
        #expect(await queue.pendingCount == 2)
        accepting.withLock { $0 = false }
        await rig.socket.releaseSends()
        await queue.waitUntilIdle()
        #expect(await queue.pendingCount == 0)
        #expect(await queue.failure as? HostConnectionFailure == .notReady)
        await queue.enqueue(ambientSegment(stream: stream, sequence: 3))
        await queue.waitUntilIdle()
        #expect(await queue.pendingCount == 0)
        #expect(try await audioFrames(rig.socket).map(\.payload) == [.audio(ambientSegment(stream: stream))])
        #expect(failures.withLock { $0 } == 0)
        await rig.connection.disconnect()
    }

    @Test func retirementDuringRouteRoundTripRejectsAudioAndNotifiesFailure() async throws {
        let (connection, socket) = try await restoredConnection()
        let accepting = Mutex(true)
        let failures = Mutex(0)
        let admission = AmbientSendAdmission { accepting.withLock { $0 } }
        let queue = AmbientAudioSendQueue(maxPending: 10, send: { try await connection.sendAudio($0) },
                                         onFailure: { _, error in
            #expect(error as? HostConnectionFailure == .notReady)
            failures.withLock { $0 += 1 }
        }, admission: admission)
        await queue.enqueue(ambientSegment())
        // The restored selection is unconfirmed. These extra select/ping frames prove entry admitted sequence 0.
        try await waitUntil { try await socket.sentFrames().count == 6 }
        #expect(try await audioFrames(socket).isEmpty)
        let frames = try await socket.sentFrames()
        #expect(frames[4].payload == .control(.select(targetID: ambientTarget)))
        guard case .control(.ping(let nonce)) = frames[5].payload else {
            throw SocketTestError.unavailable
        }
        accepting.withLock { $0 = false }
        try await socket.push(.pong(nonce: nonce))
        await queue.waitUntilIdle()
        #expect(failures.withLock { $0 } == 1)
        #expect(await queue.failure as? HostConnectionFailure == .notReady)
        #expect(try await audioFrames(socket).isEmpty)
        await connection.disconnect()
    }

    private func restoredConnection() async throws -> (HostConnection, ScriptedSocket) {
        let second = ScriptedSocket()
        let (connection, _) = try await readyAudioConnection(
            capabilities: ["select_target", "stream_audio"], sockets: [ScriptedSocket(), second]
        )
        await connection.disconnect()
        await connection.connect()
        try await awaitHello(connection, second, capabilities: ["select_target", "stream_audio"])
        try await waitUntil { try await second.sentFrames().count == 4 }
        return (connection, second)
    }
}
