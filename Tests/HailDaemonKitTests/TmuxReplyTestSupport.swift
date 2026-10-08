import Foundation
@testable import HailDaemonKit

// Invented labels, bindings and input only; no process is spawned by these fixtures.
let bridgeListing = "$1|1758230000|%1|501|bridge\n$2|1758230001|%2|502|ordinary\n"
let bridgeBinding = "$1@1758230000/%1:501"

struct BridgeRig {
    let runner: FakeCommandRunner
    let adapter: TmuxReplyAdapter
    let context: ProviderTurnContext

    init(listing: String = bridgeListing) throws {
        runner = FakeCommandRunner.serving(SessionListing(listing))
        adapter = try TmuxReplyAdapter(terminal: TmuxAdapter(runner: runner, pollInterval: nil), targets: ["bridge"])
        context = try bridgeContext()
    }
}

func bridgeContext(
    provider: String = "tmux-reply", target: String = "tmux-reply:bridge", binding: String = bridgeBinding
) throws -> ProviderTurnContext {
    let source = try ProviderSessionBinding(hostID: "synthetic-host", providerID: provider,
                                           targetID: target, sessionID: binding)
    return ProviderTurnContext(utteranceID: UUID(), connectionID: UUID(), binding: source)
}

/// Every text pasted into a pane, whole (#304); keys sent by name are left out.
func pastedTexts(on runner: FakeCommandRunner) async -> [String] {
    deliveredKeys(await runner.calls, includingKeys: false)
}

struct CapturedBridgeEnvelope: Decodable {
    let version: Int
    let request: UUID
    let text: String
}

func submittedEnvelope(on runner: FakeCommandRunner) async throws -> CapturedBridgeEnvelope {
    let line = await pastedTexts(on: runner).joined()
    return try JSONDecoder().decode(CapturedBridgeEnvelope.self, from: Data(line.utf8))
}
