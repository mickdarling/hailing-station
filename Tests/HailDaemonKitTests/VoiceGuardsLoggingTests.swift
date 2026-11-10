import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .frozenGuardBudget) struct VoiceGuardsLoggingTests {
    @Test func namesAreEscapedAndDeduplicatedAcrossLinesAndNoContentLeaks() async throws {
        let name = "synthetic \"rule\"\n\\name"
        let policy = Policy(guardPatterns: [.init(name: name, regex: "guarded")], voiceGuards: .off)
        let adapter = FinalDeliveryAdapter()
        let route = try await VoiceGuardsRoute.make(adapter: adapter, policy: policy,
                                                   sanitizing: .init(newlines: .split))
        _ = try await route.ambient("guarded private-utterance\nguarded private-prompt")
        #expect(await adapter.deliveries.count == 2)
        #expect(route.log.lines.count == 1)
        let object = try route.log.object()
        #expect(Set(object.keys) == ["event", "rules"])
        #expect(object["event"] as? String == "voice_guard_skipped")
        #expect(object["rules"] as? [String] == [name])
        #expect(!route.log.lines[0].contains("private-"))
        #expect(!route.log.lines[0].contains(route.target))
        #expect(!route.log.lines[0].contains(route.binding))
        #expect(route.log.lines[0].split(separator: "\n").count == 1)
        await route.listener.stop()
    }

    @Test(arguments: VoiceGuards.allCases)
    func timeoutIsNotReportedAsAMatch(_ setting: VoiceGuards) async throws {
        let adapter = FinalDeliveryAdapter()
        let route = try await VoiceGuardsRoute.make(adapter: adapter,
            policy: Policy(guardPatterns: [VoiceGuardsRoute.rule], voiceGuards: setting))
        // A missing CPU clock deterministically produces a timeout, without regex cost or wall sleeps.
        try await GuardBudgetClock.$current.withValue(.init(now: { .now }, cpuNow: { nil })) {
            if setting == .off {
                _ = try await route.ambient("synthetic nonmatching text")
            } else {
                await #expect(throws: LocalDispatchRefusal.confirmationRequired) {
                    try await route.ambient("synthetic nonmatching text")
                }
            }
        }
        if setting == .off {
            #expect(await adapter.deliveries == ["synthetic nonmatching text"])
            #expect(route.log.lines.count == 1)
            let object = try route.log.object()
            #expect(Set(object.keys) == ["event", "rules", "timeout", "timeoutRules"])
            #expect(object["rules"] as? [String] == [])
            #expect(object["timeout"] as? Bool == true)
            #expect(object["timeoutRules"] as? [String] == [VoiceGuardsRoute.rule.name])
        } else {
            #expect(await adapter.deliveries.isEmpty)
            #expect(route.log.lines.isEmpty)
        }
        await route.listener.stop()
    }

    @Test func aCleanScanDoesNotEmitASkipEvent() async throws {
        let route = try await VoiceGuardsRoute.make(adapter: FinalDeliveryAdapter())
        _ = try await route.ambient("synthetic nonmatching text")
        #expect(route.log.lines.isEmpty)
        await route.listener.stop()
    }
}
