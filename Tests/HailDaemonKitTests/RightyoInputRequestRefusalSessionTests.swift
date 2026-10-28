import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Synthetic sessions and never-started transports; no microphone, device playback or network handoff.
@Suite(.frozenGuardBudget) struct RightyoInputRequestRefusalSessionTests {
    private let text = "sudo SYNTHETIC_TOKEN"
    private let target = "tmux:demo"
    private let binding = "original"

    @Test func ambientConfirmationRefusalLeavesNoPendingReadBack() async throws {
        let rig = try await makeRig()
        let request = LocalDispatchRequest(
            connection: await rig.session.connectionID, target: target, binding: binding, text: text
        )
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) {
            try await rig.listener.dispatchAmbient(
                request, reference: UUID(), selection: await rig.session.selectionGeneration
            )
        }
        #expect(await rig.session.replyRequests.isEmpty)
        #expect(await rig.adapter.deliveries.isEmpty)
        #expect(await rig.host.cancel(confirmationHash(device: HostSession.dispatchDevice)) == false)
        await rig.listener.stop(reason: "synthetic test complete")
    }

    @Test(arguments: [false, true])
    func nonAmbientInputKeepsConfirmationAtTheMac(localDispatch: Bool) async throws {
        let rig = try await makeRig()
        if localDispatch {
            await #expect(throws: LocalDispatchRefusal.confirmationRequired) {
                try await rig.session.dispatch(.init(
                    connection: UUID(), target: target, binding: binding, text: text
                ))
            }
        } else {
            let result = await rig.session.receive(sessionFrame(
                target: target, payload: .text(TextPayload(text: text))
            ))
            #expect(try onlyControl(result) == .error(
                code: .notAllowed, message: "target requires confirmation at the Mac"
            ))
        }
        #expect(await rig.adapter.deliveries.isEmpty)
        let device = localDispatch ? HostSession.dispatchDevice : "test"
        let hash = confirmationHash(device: device)
        #expect(try await rig.host.send(text, to: target, from: device, confirmedHash: hash) == .delivered([text]))
        #expect(await rig.adapter.deliveries.map(\.text) == [text])
        #expect(await rig.host.cancel(hash) == false)
        await rig.listener.stop(reason: "synthetic test complete")
    }

    private func confirmationHash(device: String) -> String {
        DeliveryRequest(target: target, binding: binding, lines: [text], device: device).confirmationHash
    }

    private struct Rig {
        let host: HailHost
        let adapter: FakeAdapter
        let session: HostSession
        let listener: WebSocketListener
    }

    private func makeRig() async throws -> Rig {
        var policy = Policy()
        try policy.allow(target, binding: binding, tier: .open)
        let (host, adapter) = try await sessionHost(targets: [.init(name: "demo", binding: binding)], policy: policy)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: host, authorizer: PersonalTerminalAuthorizer(),
            hostName: "mac-test"
        )
        await listener.installFallbackSyntheticPeers([session])
        return Rig(host: host, adapter: adapter, session: session, listener: listener)
    }
}
