import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct SessionUpdateReviewRepairsTests {
    @Test(arguments: [false, true])
    func actualListenerHelloNegotiatesOnlyTheExplicitlyEnabledUpdatePath(_ enabled: Bool) async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        if enabled { await listener.enableSessionUpdates() }
        let port = try await listener.start()
        do {
            let (client, socket) = try recipientSocket(port: port)
            defer { socket.cancel(with: .normalClosure, reason: nil); client.invalidateAndCancel() }
            try await recipientSocketSend(helloFrame(capabilities: [SessionUpdateCard.capability]), on: socket)
            let hello = try await recipientSocketReceive(on: socket)
            guard case .control(.hello(let info)) = hello.payload else {
                Issue.record("expected actual host hello"); await listener.stop(); return
            }
            #expect(info.capabilities.contains(SessionUpdateCard.capability) == enabled)
            if enabled {
                // Use the host's negotiated capability, as the device does, rather than a fabricated host hello.
                try #require(info.capabilities.contains(SessionUpdateCard.capability))
                try await recipientSocketSend(sessionFrame(payload: .control(.select(
                    targetID: RecipientTestRig.target))), on: socket)
                try await recipientSocketBarrier(on: socket, step: "selected update destination")
                try await recipientSocketSend(sessionFrame(target: RecipientTestRig.target,
                    payload: .text(TextPayload(text: "Synthetic input"))), on: socket)
                try await recipientSocketBarrier(on: socket)
                let result = await listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                    priority: .action, text: "Synthetic progress"))
                #expect(result.outcome == .delivered)
                let delivered = try await recipientSocketReceive(on: socket)
                #expect(delivered.target == RecipientTestRig.target)
                guard case .control(.sessionUpdate) = delivered.payload else {
                    Issue.record("expected negotiated update card"); await listener.stop(); return
                }
            }
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }

    @Test func privacyOnOffBeforeThePeerActorEntryCannotRefreshTheOfferedUpdatesEpoch() async throws {
        let sends = Mutex(0)
        let rig = try await SessionUpdateListenerRig.make(send: { complete in
            sends.withLock { $0 += 1 }; complete(nil)
        })
        _ = await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                                                  text: "Synthetic old progress"))
        let hold = await rig.listener.replyHold
        let delivered = await SessionUpdatePrivacyScope.$beforePeerHop.withValue({
            // This executes after listener admission but before the peer method's actor entry. Recapturing the
            // epoch in that peer method would incorrectly authorize this old offered update after the exit.
            hold.set(true, connection: rig.connectionID)
            hold.set(false, connection: rig.connectionID)
        }, operation: { await rig.listener.drainSessionUpdates(.interaction) })
        #expect(delivered.isEmpty && sends.withLock { $0 } == 0)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        await rig.listener.stop()
    }
}
