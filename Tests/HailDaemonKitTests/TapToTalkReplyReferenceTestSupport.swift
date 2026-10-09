import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// A final tap-to-talk text frame, as the phone sends it.
func tapToTalkFrame(_ text: String, target: String = LegacyReferenceRig.target) -> Frame {
    sessionFrame(target: target, payload: .text(TextPayload(text: text, isFinal: true)))
}

/// Sends one tap-to-talk utterance and returns the reference its footer names.
func tapToTalk(_ session: HostSession, rig: LegacyReferenceRig, text: String = "synthetic input") async throws -> UUID {
    try #require(await session.receive(tapToTalkFrame(text)).frames.isEmpty)
    let typed = try #require(await rig.adapter.deliveries.last?.text)
    let reference = try #require(blockReference(in: typed))
    try #require(await session.replyRequests[reference] != nil)
    return reference
}

/// A one-target legacy rig with its own name, tier or authored guard (the shared rig's are fixed).
func legacyRig(
    name: String = "reply", tier: Tier = .open,
    guard pattern: GuardPattern = .init(name: "synthetic guard", regex: "^synthetic guarded command$")
) async throws -> LegacyReferenceRig {
    let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: name, binding: "binding")])
    let registry = Registry()
    try await registry.register(adapter)
    var policy = Policy(guardPatterns: [pattern], deliveriesPerMinute: 1_000)
    try policy.allow("tmux:" + name, binding: "binding", tier: tier)
    let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
    return LegacyReferenceRig(host: host, adapter: adapter)
}

extension LegacyReferenceRig {
    func session(selecting target: String) async -> HostSession {
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test",
                                  now: clock.now, requestClock: clock.instant)
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        return session
    }
}
