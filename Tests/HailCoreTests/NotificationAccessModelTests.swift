#if os(macOS)
import Testing
import UserNotifications

@MainActor
@Suite(.serialized) struct NotificationAccessModelTests {
    @Test func constructionIsInertAndDuplicateChecksShareOneExplicitRead() async throws {
        let reader = NotificationAccessReaderSpy()
        let owner = NotificationAccessModel(read: { await reader.read() })
        #expect(owner.status == nil && !owner.isChecking)
        #expect(await reader.calls == 0)
        let first = try #require(owner.check())
        #expect(owner.isChecking && owner.status == nil)
        #expect(owner.check() == nil)
        try await waitUntil { await reader.calls == 1 }
        try await reader.finish(1, with: .denied)
        await first.value
        #expect(owner.status == .denied && !owner.isChecking)
        let second = try #require(owner.check())
        #expect(owner.status == .denied && owner.isChecking, "The previous snapshot is not a fresh result")
        try await waitUntil { await reader.calls == 2 }
        try await reader.finish(2, with: .authorized)
        await second.value
        #expect(owner.status == .authorized && !owner.isChecking)
    }

    @Test func aCancelledReadCannotOverwriteTheLastSnapshotAndCanBeCheckedAgain() async throws {
        let reader = NotificationAccessReaderSpy()
        let owner = NotificationAccessModel(read: { await reader.read() })
        let first = try #require(owner.check())
        try await waitUntil { await reader.calls == 1 }
        try await reader.finish(1, with: .authorized)
        await first.value
        let cancelled = try #require(owner.check())
        try await waitUntil { await reader.calls == 2 }
        cancelled.cancel()
        #expect(owner.check() == nil, "A cancelled OS callback must settle before another read can start")
        try await reader.finish(2, with: .denied)
        await cancelled.value
        #expect(owner.status == .authorized && !owner.isChecking)
        let next = try #require(owner.check())
        try await waitUntil { await reader.calls == 3 }
        try await reader.finish(3, with: .provisional)
        await next.value
        #expect(owner.status == .provisional && !owner.isChecking)
    }

    @Test func aReleasedOwnersLateCompletionCannotAffectANewOwner() async throws {
        let stale = NotificationAccessReaderSpy(), fresh = NotificationAccessReaderSpy()
        var old: NotificationAccessModel? = NotificationAccessModel(read: { await stale.read() })
        weak var previous = old
        let oldTask = try #require(old?.check())
        try await waitUntil { await stale.calls == 1 }
        old = nil
        #expect(previous == nil, "A held status read cannot retain the old window owner")
        let replacement = NotificationAccessModel(read: { await fresh.read() })
        let current = try #require(replacement.check())
        try await waitUntil { await fresh.calls == 1 }
        try await fresh.finish(1, with: .authorized)
        await current.value
        try await stale.finish(1, with: .denied)
        await oldTask.value
        #expect(replacement.status == .authorized && !replacement.isChecking)
        #expect(await fresh.calls == 1)
        #expect(await stale.calls == 1)
    }

    @Test func knownSDKStatusesMapWithoutPerformingAnOSRead() {
        let cases: [(UNAuthorizationStatus, NotificationAccessStatus)] = [
            (.notDetermined, .notDetermined), (.denied, .denied),
            (.authorized, .authorized), (.provisional, .provisional)
        ]
        for (system, expected) in cases { #expect(SystemNotificationAccessReader.map(system) == expected) }
    }

    @Test(arguments: [NotificationAccessStatus.notDetermined, .denied, .authorized, .provisional,
                      .ephemeral, .unknown(999)])
    func allStatusValuesRemainDistinctAndRenderable(status: NotificationAccessStatus) async throws {
        let reader = NotificationAccessReaderSpy()
        let owner = NotificationAccessModel(read: { await reader.read() })
        let task = try #require(owner.check())
        try await waitUntil { await reader.calls == 1 }
        try await reader.finish(1, with: status)
        await task.value
        #expect(owner.status == status && !owner.isChecking)
        #expect(!status.title.isEmpty && !status.detail.isEmpty)
        #expect(status.title != "Not checked")
    }
}
#endif
