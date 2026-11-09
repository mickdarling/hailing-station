import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct HostSessionDialogNoticeTests {
    static let block = DialogBlock(cause: .uninspectable, effects: .pasteMayHaveExecuted)

    @Test(arguments: [0, 1, 2])
    func typedOutcomeAndLocalDispatchKeepOnlyTheCount(_ earlier: Int) async throws {
        let session = try await ready(earlier: earlier)
        let frame = sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: "one\ntwo\nthree")))
        let input = try await authorizedInput(session, frame, device: "synthetic")
        let outcome = await session.deliver(input, recordsLastInput: true)
        #expect(outcome == .blockedByDialog(Self.block, earlierDelivered: earlier))
        #expect(await session.replyRequests.isEmpty)
        #expect(await session.lastInputLedger?.latest(for: "tmux:a") == nil)
        let expected = LocalDispatchRefusal.blockedByDialog(Self.block, earlierDelivered: earlier)
        let local = try await ready(earlier: earlier)
        let request = LocalDispatchRequest(connection: UUID(), target: "tmux:a", binding: "b1",
                                           text: "one\ntwo\nthree")
        await #expect(throws: expected) { try await local.dispatch(request) }
        #expect(!expected.handedOff)
        #expect(expected.code == LocalDispatchRefusal.deliveryRefused.code)
    }

    @Test(arguments: [0, 2], [(false, false), (false, true), (true, false), (true, true)])
    func phoneKeepsTheExistingErrorCode(earlier: Int, device: (capable: Bool, paste: Bool)) async throws {
        let session = try await ready(earlier: earlier, capable: device.capable)
        let payload = TextPayload(text: "synthetic request", pasted: device.paste ? PastedText(text: "notes") : nil)
        let result = await session.receive(sessionFrame(target: "tmux:a", payload: .text(payload)))
        let code: ErrorCode = device.capable && device.paste ? .pasteRefused : .notAllowed
        let notice = DialogDeliveryNotice(block: Self.block, earlierDelivered: earlier)
        let control = try onlyControl(result)
        #expect(control == .error(code: code, message: notice.message(target: "a")))
        #expect(await session.replyRequests.isEmpty)
        #expect(await session.lastInputLedger?.latest(for: "tmux:a") == nil)
    }

    @Test func legacyTokensRemainStableAndDialogEvidenceCannotBeDecodedFromAToken() {
        let tokens = ["unsupported", "unknownConnection", "connectionEnded", "sessionNotReady", "notAuthorized",
                      "targetNotSelected", "selectionChanged", "bindingMismatch", "confirmationRequired",
                      "capacityExceeded", "deliveryRefused", "ownershipLost", "connectionLost", "inputPending"]
        for token in tokens {
            let refusal = LocalDispatchRefusal(rawValue: token)
            #expect(refusal?.rawValue == token)
            #expect(refusal?.description == token)
        }
        #expect(LocalDispatchRefusal(rawValue: "blockedByDialog") == nil)
        #expect(LocalDispatchRefusal(rawValue: "unknown") == nil)
        let dialog = LocalDispatchRefusal.blockedByDialog(Self.block, earlierDelivered: 2)
        #expect(dialog.rawValue == "blockedByDialog")
        #expect(dialog.description == "blockedByDialog")
        #expect(dialog.message == "dispatch refused [blockedByDialog]: target is blocked by a dialog")
    }

    private func ready(earlier: Int, capable: Bool = false) async throws -> HostSession {
        let error: any Error = earlier == 0 ? AdapterError.blockedByDialog(Self.block)
            : HostError.partial(delivered: Array(repeating: "synthetic private line", count: earlier),
                                reason: .dialog(Self.block))
        let adapter = FakeAdapter(kind: "tmux", targets: [.init(name: "a", binding: "b1")], deliverError: error)
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")],
                            deliveriesPerMinute: 1_000)
        try policy.allow("tmux:a", binding: "b1", tier: .open)
        let host = try HailHost(registry: registry, sanitizing: .init(newlines: .split),
                               store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        await session.installDialogTestLedger()
        _ = await session.receive(helloFrame(capabilities: capable ? [RequestRefusals.capability] : []))
        await session.forceSelection("tmux:a")
        return session
    }
}

private extension HostSession {
    func installDialogTestLedger() { lastInputLedger = LastInputLedger() }
}
