import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct RegistryMergeTests {
    @Test func mergesAdaptersUnderStableIdsSortedById() async throws {
        let registry = Registry()
        try await registry.register(FakeAdapter(kind: "tmux", targets: [
            AdapterTarget(name: "claude-hail"), AdapterTarget(name: "codex", alive: false)
        ]))
        try await registry.register(FakeAdapter(kind: "console", targets: [
            AdapterTarget(name: "s1", displayName: "Discord MCP Server")
        ]))

        let targets = try await registry.targets()

        #expect(targets == [
            TargetInfo(id: "console:s1", kind: "console", name: "Discord MCP Server", alive: true),
            TargetInfo(id: "tmux:claude-hail", kind: "tmux", name: "claude-hail", alive: true),
            TargetInfo(id: "tmux:codex", kind: "tmux", name: "codex", alive: false)
        ])
        #expect(await registry.lastFailures.isEmpty)
    }

    @Test func failingAdapterIsSkippedAndNamedNotFatal() async throws {
        let registry = Registry()
        try await registry.register(FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a")]))
        try await registry.register(FakeAdapter(kind: "broken", listError: AdapterError.captureFailed("boom")))

        let targets = try await registry.targets()

        #expect(targets.map(\.id) == ["tmux:a"])
        #expect(await registry.lastFailures == ["broken": "captureFailed(\"boom\")"])
    }

    @Test func duplicateNamesWithinOneAdapterAreDroppedAndReported() async throws {
        let registry = Registry()
        try await registry.register(FakeAdapter(kind: "tmux", targets: [
            AdapterTarget(name: "a"), AdapterTarget(name: "a", alive: false), AdapterTarget(name: "b")
        ]))

        let targets = try await registry.targets()

        #expect(targets.map(\.id) == ["tmux:a", "tmux:b"])
        #expect(targets[0].alive)
        #expect(await registry.lastFailures == ["tmux": "duplicate target name a"])

        try await registry.register(FakeAdapter(kind: "console", targets: [AdapterTarget(name: "a")]))
        #expect(try await registry.targets().map(\.id) == ["console:a", "tmux:a", "tmux:b"])
        #expect(await registry.lastFailures.keys.sorted() == ["tmux"])
    }

    @Test func rejectsKindsThatWouldBreakIds() async throws {
        let registry = Registry()
        for bad in ["", "Tmux", "tm ux", "tmux:x", "tmüx"] {
            await #expect(throws: RegistryError.invalidKind(bad)) {
                try await registry.register(FakeAdapter(kind: bad))
            }
        }
        try await registry.register(FakeAdapter(kind: "tmux"))
        await #expect(throws: RegistryError.duplicateKind("tmux")) {
            try await registry.register(FakeAdapter(kind: "tmux"))
        }
        #expect(await registry.kinds == ["tmux"])
    }

    @Test func listingCarriesEachBindingAndTheWireListDoesNot() async throws {
        let registry = Registry()
        try await registry.register(FakeAdapter(kind: "tmux", targets: [
            AdapterTarget(name: "a", binding: "$1@1/%1:1"), AdapterTarget(name: "b")
        ]))

        let listed = try await registry.listing()

        #expect(listed.map(\.binding) == ["$1@1/%1:1", nil])
        #expect(listed.map(\.info.id) == ["tmux:a", "tmux:b"])
        #expect(try await registry.targets() == listed.map(\.info))
    }

    @Test func resolvesIdsAtTheFirstColonOnly() async throws {
        let registry = Registry()
        try await registry.register(FakeAdapter(kind: "http", targets: [AdapterTarget(name: "host:8080/x")]))

        try await registry.deliver("hi", to: "http:host:8080/x", binding: nil)

        let adapter = try #require(await resolveFake(registry, "http:host:8080/x"))
        #expect(await adapter.deliveries.map(\.target) == ["host:8080/x"])
        for bad in ["http", "http:", ":name", "tmux:a", "HTTP:host:8080/x"] {
            await #expect(throws: RegistryError.unknownTarget(bad)) {
                try await registry.deliver("x", to: bad, binding: nil)
            }
        }
    }

    @Test func emptyNamesAreDroppedAndReportedNeverAdvertised() async throws {
        let registry = Registry()
        let listed = [AdapterTarget(name: ""), AdapterTarget(name: "a")]
        try await registry.register(FakeAdapter(kind: "tmux", targets: listed))

        #expect(try await registry.targets().map(\.id) == ["tmux:a"])
        #expect(await registry.lastFailures == ["tmux": "empty target name"])
    }

    @Test func cancellationPropagatesWithoutRecordingFailures() async throws {
        let registry = Registry()
        try await registry.register(FakeAdapter(kind: "tmux", listError: CancellationError()))
        try await registry.register(FakeAdapter(kind: "z", targets: [AdapterTarget(name: "a")]))

        await #expect(throws: CancellationError.self) { try await registry.targets() }
        #expect(await registry.lastFailures.isEmpty)
    }

    private func resolveFake(_ registry: Registry, _ id: String) async throws -> FakeAdapter? {
        try await registry.resolve(id).adapter as? FakeAdapter
    }
}
