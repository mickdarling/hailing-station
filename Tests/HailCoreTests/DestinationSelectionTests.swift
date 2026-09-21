import Foundation
import HailProtocol
import Testing
@testable import HailCore

struct DestinationSelectionTests {
    @Test func matchesOnlyTheSameLiveTargetNameAndIdentity() {
        let selection = DestinationSelection(hostID: "mac-1", targetID: "tmux:one", targetName: "one")

        #expect(selection.matches(
            hostID: "mac-1", target: TargetInfo(id: "tmux:one", kind: "tmux", name: "one", alive: true)
        ))
        #expect(!selection.matches(
            hostID: "mac-2", target: TargetInfo(id: "tmux:one", kind: "tmux", name: "one", alive: true)
        ))
        #expect(!selection.matches(
            hostID: "mac-1", target: TargetInfo(id: "tmux:one", kind: "tmux", name: "renamed", alive: true)
        ))
        #expect(!selection.matches(
            hostID: "mac-1", target: TargetInfo(id: "tmux:one", kind: "tmux", name: "one", alive: false)
        ))
    }

    @Test func userDefaultsStoreRoundTripsAndClears() async throws {
        let suite = "DestinationSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsDestinationSelectionStore(suiteName: suite)
        let selection = DestinationSelection(hostID: "mac-1", targetID: "tmux:one", targetName: "one")

        await store.save(selection)
        #expect(await store.load() == selection)

        await store.save(nil)
        #expect(await store.load() == nil)
    }

    @Test func corruptStoredSelectionFailsClosed() async throws {
        let suite = "DestinationSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: "selection")
        let store = UserDefaultsDestinationSelectionStore(key: "selection", suiteName: suite)

        #expect(await store.load() == nil)
    }
}
