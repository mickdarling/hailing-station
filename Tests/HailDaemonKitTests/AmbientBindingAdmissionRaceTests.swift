import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBindingAdmissionRaceTests {
    @Test(arguments: ["deny", "denyReallow", "selectAway", "selectAwayAndBack"])
    func aSuspendedListingCannotAdmitStaleAuthority(change: String) async throws {
        let adapter = GatedListingFakeAdapter(AdapterTarget(name: "a", binding: "binding-a"))
        let host = try await host(for: adapter)
        let sink = RecordingAmbientSink()
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
        let generation = host.targetPolicy.snapshot(for: "tmux:a")
        await adapter.gateNextListing()
        let receiving = Task {
            await session.receive(sessionFrame(target: "tmux:a",
                payload: .audio(ambientSegment(stream: UUID(), sequence: 0))))
        }
        await adapter.nextListingArrival()
        if change.hasPrefix("deny") {
            _ = try await host.deny("tmux:a")
            if change == "denyReallow" { _ = try await host.allow("tmux:a", tier: .open) }
        } else {
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "other:b"))))
            if change == "selectAwayAndBack" {
                _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
            }
        }
        await adapter.releaseListing()
        let result = await receiving.value
        #expect(!result.frames.isEmpty)
        #expect(sink.events.isEmpty)
        #expect(await gate.activeStream == nil)
        #expect(await adapter.deliveries.isEmpty)
        if change.hasPrefix("deny") { #expect(generation.performIfCurrent({ true }) != true) }
        // The refusal consumes no PCM. Only another fresh admission under current authority may recover.
        if change != "deny" {
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
            let fresh = await session.receive(sessionFrame(target: "tmux:a",
                payload: .audio(ambientSegment(stream: UUID(), sequence: 0, isFinal: true))))
            #expect(fresh.frames.isEmpty)
            #expect(sink.segments == [0])
        }
    }

    @Test(arguments: ["wrongTarget", "wrongSelection", "wrongShape", "denied"])
    func cheapOpeningRefusalsDoNotListTheRegistry(reason: String) async throws {
        let adapter = GatedListingFakeAdapter(AdapterTarget(name: "a", binding: "binding-a"))
        let host = try await host(for: adapter)
        let sink = RecordingAmbientSink()
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        _ = await session.receive(helloFrame())
        let selected = reason == "wrongSelection" ? "other:b" : "tmux:a"
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: selected))))
        if reason == "denied" { _ = try await host.deny("tmux:a") }
        let before = await adapter.listingCount
        for _ in 0..<3 {
            var audio = ambientSegment(stream: UUID(), sequence: 0)
            if reason == "wrongShape" { audio.sampleRate = 8_000 }
            let target = reason == "wrongTarget" ? "other:b" : "tmux:a"
            let result = await session.receive(sessionFrame(target: target, payload: .audio(audio)))
            #expect(!result.frames.isEmpty)
        }
        #expect(await adapter.listingCount == before)
        #expect(sink.events.isEmpty)
        #expect(await gate.activeStream == nil)
    }

    private func host(for adapter: GatedListingFakeAdapter) async throws -> HailHost {
        let registry = Registry()
        try await registry.register(adapter)
        try await registry.register(FakeAdapter(kind: "other", targets: [AdapterTarget(name: "b", binding: "b")]))
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .open)
        try policy.allow("other:b", binding: "b", tier: .open)
        return try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
    }
}
