import Foundation
import HailProtocol
import Testing
@testable import HailCore

struct DestinationSelectionTests {
    @Test func matchesOnlyTheSameLiveTargetNameAndIdentity() throws {
        let original = try HostEndpoint(
            id: "mac-1", name: "Mac", url: #require(URL(string: "ws://mac-one:8765"))
        )
        let edited = try HostEndpoint(
            id: "mac-1", name: "Mac", url: #require(URL(string: "ws://mac-two:8765"))
        )
        let selection = DestinationSelection(
            hostID: original.id,
            hostURL: original.url.absoluteString,
            targetID: "tmux:one",
            targetName: "one"
        )

        #expect(selection.matches(
            endpoint: original, target: TargetInfo(id: "tmux:one", kind: "tmux", name: "one", alive: true)
        ))
        #expect(!selection.matches(
            endpoint: edited, target: TargetInfo(id: "tmux:one", kind: "tmux", name: "one", alive: true)
        ))
        #expect(!selection.matches(
            endpoint: original, target: TargetInfo(id: "tmux:one", kind: "tmux", name: "renamed", alive: true)
        ))
        #expect(!selection.matches(
            endpoint: original, target: TargetInfo(id: "tmux:one", kind: "tmux", name: "one", alive: false)
        ))
    }

    @Test func userDefaultsStoreRoundTripsAndClears() async throws {
        let suite = "DestinationSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsDestinationSelectionStore(suiteName: suite)
        let selection = DestinationSelection(
            hostID: "mac-1", hostURL: "ws://mac-one:8765", targetID: "tmux:one", targetName: "one"
        )

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
