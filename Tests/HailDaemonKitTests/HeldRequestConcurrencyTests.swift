import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct HeldRequestConcurrencyTests {
    @Test func overlappingSendAndDiscardHaveOnlyOneHandoff() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        await rig.adapter.holdNextListing()
        var arrivals = rig.adapter.listingEvents.stream.makeAsyncIterator()
        async let first = rig.send(entry.id)
        _ = await arrivals.next()
        async let duplicate = rig.send(entry.id)
        async let conflicting = rig.discard(entry.id)
        await rig.adapter.releaseListing()
        #expect(await first == .sent)
        #expect(await duplicate == .sent)
        #expect(await conflicting == .sent)
        #expect(await rig.adapter.contexts.count == 1)
    }

    @Test func selectionChangeDuringFreshListingCannotDeliver() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        await rig.adapter.holdNextListing()
        var arrivals = rig.adapter.listingEvents.stream.makeAsyncIterator()
        async let send = rig.send(entry.id)
        _ = await arrivals.next()
        await rig.select("recipient:other")
        await rig.select(RecipientTestRig.target)
        await rig.adapter.releaseListing()
        #expect(await send == .refused(.selectionChanged))
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
    }

    @Test func uncertainAdapterHandoffBlocksSubsequentSendUntilReconciliation() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        await rig.adapter.failHandoff()
        #expect(await rig.send(entry.id) == .refused(.denied))
        await rig.adapter.passHandoff()
        #expect(await rig.send(entry.id) == .refused(.denied))
        #expect(await rig.adapter.contexts.count == 1)
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
        #expect(await rig.discard(entry.id) == .discarded)
    }
}
