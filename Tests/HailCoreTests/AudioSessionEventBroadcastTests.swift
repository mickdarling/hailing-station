import Testing
@testable import HailCore

struct AudioSessionEventBroadcastTests {
    @Test func subscribersReceiveIndependentCopiesOfEvents() async {
        let broadcast = AudioSessionEventBroadcast()
        var first = broadcast.stream().makeAsyncIterator()
        var second = broadcast.stream().makeAsyncIterator()

        broadcast.yield(.interruptionBegan)

        #expect(await first.next() == .interruptionBegan)
        #expect(await second.next() == .interruptionBegan)
    }

    @Test func cancelingOneSubscriberDoesNotRemoveAnother() async {
        let broadcast = AudioSessionEventBroadcast()
        let firstStream = broadcast.stream()
        var second = broadcast.stream().makeAsyncIterator()
        let first = Task {
            for await _ in firstStream {}
        }
        #expect(broadcast.subscriberCount == 2)

        first.cancel()
        await eventually { broadcast.subscriberCount == 1 }
        broadcast.yield(.interruptionEnded(resumed: true))

        #expect(await second.next() == .interruptionEnded(resumed: true))
    }

    @Test func lateSubscriberReceivesLaterEvents() async {
        let broadcast = AudioSessionEventBroadcast()
        broadcast.yield(.interruptionBegan)
        var late = broadcast.stream().makeAsyncIterator()

        broadcast.yield(.routeChanged(.inactive))

        #expect(await late.next() == .routeChanged(.inactive))
    }

    @Test func finishEndsEveryRemainingSubscription() async {
        let broadcast = AudioSessionEventBroadcast()
        var first = broadcast.stream().makeAsyncIterator()
        var second = broadcast.stream().makeAsyncIterator()

        broadcast.finish()

        #expect(await first.next() == nil)
        #expect(await second.next() == nil)
        #expect(broadcast.subscriberCount == 0)
    }
}

private func eventually(
    _ predicate: @escaping @Sendable () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<100 where !predicate() {
        await Task.yield()
    }
    #expect(predicate(), sourceLocation: sourceLocation)
}
