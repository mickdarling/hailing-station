import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct HeldRequestFreshChecksTests {
    @Test func globalPolicyChangeCannotReuseOldConfirmation() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        var policy = rig.store.stored
        policy.guardPatterns = [.init(name: "replacement guard", regex: "NEVER_MATCHES")]
        rig.store.overwrite(policy)
        #expect(await rig.send(entry.id) == .refused(.policyChanged))
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
        #expect(await rig.adapter.contexts.isEmpty)
    }

    @Test func capacityRefusalRetainsTheHold() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        for _ in 0..<HostReplyRequest.capacity {
            _ = try await rig.session.dispatch(dispatchRequest(connection: entry.connection))
        }
        #expect(await rig.send(entry.id) == .refused(.capacity))
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
    }

    @Test func privacyChangingDuringListingIsCheckedAgain() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        await rig.adapter.holdNextListing()
        var arrivals = rig.adapter.listingEvents.stream.makeAsyncIterator()
        async let send = rig.send(entry.id)
        _ = await arrivals.next()
        rig.privacy.isOn = true
        await rig.adapter.releaseListing()
        #expect(await send == .refused(.lockdown))
        rig.privacy.isOn = false
        #expect(await rig.send(entry.id) == .sent)
    }

    @Test func heldLogFieldsOnlyContainClosedTokens() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold("HELD_TOKEN synthetic private text")
        #expect(entry.logDetail == "reasons=rule_match rules=custom")
        #expect(!entry.logDetail.contains(entry.text))
        #expect(!entry.logDetail.contains("private rule"))
        #expect(!entry.logDetail.contains(entry.readBack.hash))
        let encoded = try JSONEncoder().encode(entry.notice)
        let notice = try #require(String(data: encoded, encoding: .utf8))
        #expect(!notice.contains("HELD_TOKEN"))
        #expect(!notice.contains("private rule"))
    }
}
