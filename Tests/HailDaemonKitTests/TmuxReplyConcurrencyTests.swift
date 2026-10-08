import Foundation
import Testing
@testable import HailDaemonKit

extension TmuxReplyAdapterTests {
    @Test func concurrentContextsRemainSeparateSerializedJSONLines() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing), delay: .milliseconds(2))
        let adapter = try TmuxReplyAdapter(
            terminal: TmuxAdapter(runner: runner, chunkSize: 9, pollInterval: nil), targets: ["bridge"]
        )
        let first = try bridgeContext(), second = try bridgeContext()
        async let one: Void = adapter.deliver("synthetic one", to: "bridge", binding: bridgeBinding, context: first)
        async let two: Void = adapter.deliver("synthetic two", to: "bridge", binding: bridgeBinding, context: second)
        _ = try await (one, two)
        var line = "", envelopes: [CapturedBridgeEnvelope] = []
        for key in await runner.delivered {
            if key == "Enter" {
                envelopes.append(try JSONDecoder().decode(CapturedBridgeEnvelope.self, from: Data(line.utf8)))
                line = ""
            } else { line += key }
        }
        #expect(line.isEmpty)
        #expect(envelopes.count == 2)
        #expect(envelopes.first(where: { $0.request == first.id })?.text == "synthetic one")
        #expect(envelopes.first(where: { $0.request == second.id })?.text == "synthetic two")
    }
}
