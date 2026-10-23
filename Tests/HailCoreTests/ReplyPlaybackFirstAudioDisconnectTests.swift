import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825: deliberate transport retirement currently leaves both playback deadlines running. Scripted sockets only.
@MainActor
@Suite struct ReplyPlaybackFirstAudioDisconnectTests {
    @Test func disconnectAndReplacementPreserveTheExistingAbandonPath() async throws {
        for replace in [false, true] {
            let rig = IdleRig(), started = idleReply(), waiting = idleReply()
            let socket = ScriptedSocket(), connector = ScriptedConnector()
            let original = try endpoint("main")
            await connector.enqueue(.socket(socket), for: original.url)
            let store = HostConnectionStore(connector: connector,
                                            deadlineSleep: { _ in throw CancellationError() })
            store.onReplyFrame = { rig.controller.ingest($0) }
            await store.upsert(original)
            await store.connect(original.id)
            try await waitUntil { try await socket.sentFrames().count == 1 }
            try await socket.push(.hello(HelloInfo(versions: [ProtocolVersion.current],
                                                   capabilities: ["receive_replies"], deviceName: "Mac")))
            try await socket.push(FrameCoding.encode(idleAudio(started, sequence: 0, final: false, byte: 7).frame))
            try await socket.push(FrameCoding.encode(firstAudioText(waiting).frame))
            try await waitUntil { await MainActor.run { rig.controller.replies.count == 2 } }
            #expect(rig.liveDeadlineCount == 2)
            if replace {
                var replacement = original
                replacement.name = "Replacement"
                await store.upsert(replacement)
            } else {
                await store.disconnect(original.id)
            }
            try await waitUntil { await socket.closeCount == 1 }
            #expect(rig.player.cancelCount == 0)
            rig.advance(by: .seconds(22))
            #expect(rig.status(of: started) == ReplyPlaybackController.abandonedStatus)
            #expect(rig.status(of: waiting) == ReplyPlaybackController.abandonedStatus)
            #expect(rig.abandoned == 2)
            await store.disconnect(original.id)
        }
    }
}
