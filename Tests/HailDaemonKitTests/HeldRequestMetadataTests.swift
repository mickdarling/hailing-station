import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct HeldRequestMetadataTests {
    @Test func terminalReplayIsBoundedPerConnectionAndRetiredIDsAreStale() async throws {
        let rig = try await HeldTestRig.make()
        let template = try await rig.hold()
        let store = HeldRequestStore()
        let other = UUID()
        let otherID = try await copy(template, connection: other, into: store)
        #expect(await store.discard(otherID, from: other) == .discarded)
        var ids: [UUID] = []
        for index in 0...HeldRequestStore.terminalPerConnection {
            let id = try await copy(template, connection: template.connection, into: store)
            ids.append(id)
            if index.isMultiple(of: 2) {
                #expect(await store.send(id, from: template.connection) { _ in .sent } == .sent)
            } else { #expect(await store.discard(id, from: template.connection) == .discarded) }
        }
        #expect(await store.status(ids[0], from: template.connection) == nil)
        #expect(await store.discard(ids[0], from: template.connection) == .stale)
        #expect(await store.send(ids[0], from: template.connection) { _ in
            Issue.record("Retired terminal IDs cannot start a Send")
            return .sent
        } == .stale)
        #expect(await store.status(ids[1], from: template.connection) == .discarded)
        #expect(await store.status(try #require(ids.last), from: template.connection) == .sent)
        #expect(await store.status(otherID, from: other) == .discarded)
        #expect(await store.discard(otherID, from: template.connection) == .stale)
    }

    @Test func hostReplayBoundIncludesConnectionChurnAndKeepsUnresolvedContent() async throws {
        let rig = try await HeldTestRig.make()
        let template = try await rig.hold()
        let store = HeldRequestStore()
        let pending = try await copy(template, connection: template.connection, into: store)
        await store.markUnresolved(pending)
        var records: [(UUID, UUID)] = []
        for _ in 0...HeldRequestStore.terminalHostLimit {
            let connection = UUID()
            let id = try await copy(template, connection: connection, into: store)
            records.append((id, connection))
            #expect(await store.discard(id, from: connection) == .discarded)
        }
        var retained = 0
        for (id, connection) in records where await store.status(id, from: connection) != nil { retained += 1 }
        #expect(retained == HeldRequestStore.terminalHostLimit)
        #expect(await store.discard(records[0].0, from: records[0].1) == .stale)
        #expect(await store.status(records[1].0, from: records[1].1) == .discarded)
        #expect(await store.entries[pending]?.text == template.text)
        #expect(await store.status(pending, from: template.connection) == .unresolved)
    }

    @Test func selectionMetadataEndsWithAttemptOrRetirementWithoutDeletingHolds() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        let store = rig.host.heldRequests
        for _ in 0..<512 { store.select(UUID(), connection: UUID()) }
        #expect(store.trackedSelectionCount == 0)
        let first = store.trackSelection(entry.selection, connection: entry.connection)
        let second = store.trackSelection(entry.selection, connection: entry.connection)
        let other = store.trackSelection(UUID(), connection: UUID())
        #expect(store.trackedSelectionCount == 3)
        store.retireSelection(connection: entry.connection)
        #expect(!store.selects(first))
        #expect(!store.selects(second))
        #expect(store.selects(other))
        #expect(store.trackedSelectionCount == 1)
        store.endSelection(other)
        #expect(store.trackedSelectionCount == 0)
        #expect(await store.entries[entry.id]?.text == entry.text)
        rig.privacy.isOn = true
        #expect(await rig.send(entry.id) == .refused(.lockdown))
        #expect(store.trackedSelectionCount == 0)
        rig.privacy.isOn = false
        #expect(await rig.send(entry.id) == .sent)
        #expect(store.trackedSelectionCount == 0)
    }

    private func copy(_ entry: HeldRequestEntry, connection: UUID, into store: HeldRequestStore) async throws -> UUID {
        let reservation = try #require(await store.reserve(connection: connection))
        let copy = HeldRequestEntry(id: UUID(), connection: connection, text: entry.text, target: entry.target,
            binding: entry.binding, selection: entry.selection, policy: entry.policy, reference: entry.reference,
            route: entry.route, readBack: entry.readBack, evidence: nil, previous: entry, expires: entry.expires,
            noticeWindow: .seconds(entry.noticeSeconds))
        #expect(await store.hold(copy, reservation: reservation) != nil)
        return copy.id
    }
}
