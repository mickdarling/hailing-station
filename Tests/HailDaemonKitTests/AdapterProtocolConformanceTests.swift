import Testing
@testable import HailDaemonKit

@Suite struct AdapterProtocolConformanceTests {
    @Test func defaultEventsStreamIsEmptyAndFinishes() async {
        let adapter = FakeAdapter(kind: "tmux")
        var seen = 0
        for await _ in adapter.events { seen += 1 }
        #expect(seen == 0)
    }

    @Test func overriddenEventsStreamReachesCallersThroughTheProtocol() async {
        let sequence: [TargetEvent] = [.appeared(AdapterTarget(name: "x")), .vanished(name: "x")]
        let adapter: any Adapter = EventfulFakeAdapter(sequence)
        var seen: [TargetEvent] = []
        for await event in adapter.events { seen.append(event) }
        #expect(seen == sequence)
    }

    @Test func registryPassesAdapterLocalNamesNotIds() async throws {
        let registry = Registry()
        let tmux = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "claude-hail")])
        try await registry.register(tmux)

        try await registry.deliver("echo hi", to: "tmux:claude-hail", binding: nil)
        let tail = try await registry.capture("tmux:claude-hail")

        #expect(await tmux.deliveries.map(\.text) == ["echo hi"])
        #expect(await tmux.deliveries.map(\.target) == ["claude-hail"])
        #expect(await tmux.captures == ["claude-hail"])
        #expect(tail == "tail of claude-hail")
    }

    @Test func adapterErrorsSurfaceUnchangedThroughTheRegistry() async throws {
        let registry = Registry()
        try await registry.register(FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a")]))
        await #expect(throws: AdapterError.unknownTarget("b")) {
            try await registry.deliver("x", to: "tmux:b", binding: nil)
        }
    }
}
