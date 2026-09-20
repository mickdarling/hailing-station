import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct ConnectionProbeAuthorizationTests {
    @Test func policyFilteredListingIncludesOnlyCurrentlyBoundAllowedTargets() async throws {
        let targets = [
            AdapterTarget(name: "allowed", binding: "binding-a"),
            AdapterTarget(name: "denied", binding: "binding-b"),
            AdapterTarget(name: "rebound", binding: "binding-c-now")
        ]
        var policy = Policy()
        try policy.allow("tmux:allowed", binding: "binding-a", tier: .open)
        try policy.allow("tmux:rebound", binding: "binding-c-before", tier: .open)
        let (host, _) = try await sessionHost(targets: targets, policy: policy)
        let session = HostSession(host: host)
        _ = await session.receive(helloFrame())

        let result = await session.receive(sessionFrame(payload: .control(.listTargets)))
        guard case .targets(let listed) = try onlyControl(result) else {
            Issue.record("expected targets")
            return
        }
        #expect(listed.map(\.id) == ["tmux:allowed"])
    }

    @Test func unusablePolicyListsNoTargets() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "b")])
        let registry = Registry()
        try await registry.register(adapter)
        let host = try HailHost(
            registry: registry,
            store: InMemoryPolicyStore(loadError: PolicyFileError.malformed("bad policy"))
        )
        let session = HostSession(host: host)
        _ = await session.receive(helloFrame())

        let result = await session.receive(sessionFrame(payload: .control(.listTargets)))
        #expect(try onlyControl(result) == .targets([]))
    }

    @Test func everyActionAndMediaKindIsUnauthorizedAndNeverDelivered() async throws {
        let target = AdapterTarget(name: "a", binding: "b")
        var policy = Policy()
        try policy.allow("tmux:a", binding: "b", tier: .open)
        let (host, adapter) = try await sessionHost(targets: [target], policy: policy)
        let session = HostSession(host: host)
        _ = await session.receive(helloFrame())

        let frames: [Frame] = [
            sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: "echo unsafe"))),
            sessionFrame(payload: .audio(AudioPayload(
                codec: .pcm16, sampleRate: 16_000, channels: 1, sequence: 0, bytes: Data()
            ))),
            sessionFrame(payload: .image(ImagePayload(
                mimeType: "image/png", width: 1, height: 1, bytes: Data()
            ))),
            sessionFrame(payload: .frame(ScreenFramePayload(
                mimeType: "image/png", width: 1, height: 1, streamID: "s", index: 0, bytes: Data()
            ))),
            sessionFrame(payload: .control(.select(targetID: "tmux:a"))),
            sessionFrame(payload: .control(.subscribe(targetID: "tmux:a"))),
            sessionFrame(payload: .control(.unsubscribe(targetID: "tmux:a"))),
            sessionFrame(payload: .control(.targets([]))),
            sessionFrame(payload: .control(.pong(nonce: "x"))),
            sessionFrame(payload: .unknown(type: "future_action", payload: .object(["go": .bool(true)])))
        ]

        for frame in frames {
            let result = await session.receive(frame)
            guard case .error(let code, _) = try onlyControl(result) else {
                Issue.record("expected unauthorized for \(frame.payload)")
                continue
            }
            #expect(code == .unauthorized)
            #expect(result.disposition == .keepOpen)
        }
        #expect(await adapter.deliveries.isEmpty)
    }
}
