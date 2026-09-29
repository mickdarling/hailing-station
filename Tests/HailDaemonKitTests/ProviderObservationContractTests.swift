import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite struct ProviderObservationContractTests {
    @Test func aReplaceableObserverHasExplicitCapabilitiesAndEvents() async throws {
        let fixture = try ProviderTestFixture()
        let events = [try fixture.event(0, .accepted), try fixture.event(1, .finished)]
        let observer: any ProviderSessionObserving = SyntheticProviderObserver(events: events)
        #expect(observer.observationCapabilities == [.explicitAcceptance, .explicitCompletion])
        let observation = try await observer.observe(fixture.binding)
        defer { observation.cancel() }
        var received: [ProviderSessionEvent] = []
        for try await event in observation.events { received.append(event) }
        #expect(received == events)
    }

    @Test func observerFailureIsNotASyntheticSuccess() async throws {
        let fixture = try ProviderTestFixture()
        let observer: any ProviderSessionObserving = SyntheticProviderObserver(events: [], failure: .unavailable)
        let observation = try await observer.observe(fixture.binding)
        defer { observation.cancel() }
        await #expect(throws: ProviderObservationError.unavailable) {
            for try await _ in observation.events {}
        }
    }

    @Test func boundedOverflowEndsWithAnExplicitError() async throws {
        let fixture = try ProviderTestFixture()
        let channel = try ProviderEventChannel(capacity: 1)
        let first = try fixture.event(0, .running)
        #expect(channel.yield(first))
        #expect(!channel.yield(try fixture.event(1, .finished)))
        #expect(!channel.yield(try fixture.event(2, .accepted)))
        var iterator = channel.stream.makeAsyncIterator()
        #expect(try await iterator.next() == first)
        await #expect(throws: ProviderObservationError.bufferOverflow) { try await iterator.next() }
    }

    @Test func terminationCallbackProvidesAnObservationCleanupBoundary() async throws {
        let termination = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let channel = try ProviderEventChannel(onTermination: { termination.continuation.yield(()) })
        channel.finish(throwing: ProviderObservationError.interrupted)
        var iterator = termination.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        await #expect(throws: ProviderObservationError.interrupted) {
            for try await _ in channel.stream {}
        }
        termination.continuation.finish()
    }

    @Test func channelRejectsUnboundedOrZeroCapacity() {
        for capacity in [0, -1, ProviderEventLimits.maxBufferedEvents + 1] {
            #expect(throws: ProviderContractError.invalidCapacity) { try ProviderEventChannel(capacity: capacity) }
        }
    }

    @Test func cancellingAConsumerInvokesObservationCleanup() async throws {
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let termination = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let channel = try ProviderEventChannel(onTermination: { termination.continuation.yield(()) })
        let consumer = Task {
            started.continuation.yield(())
            for try await _ in channel.stream {}
        }
        var startIterator = started.stream.makeAsyncIterator()
        #expect(await startIterator.next() != nil)
        consumer.cancel()
        _ = try? await consumer.value
        var terminationIterator = termination.stream.makeAsyncIterator()
        #expect(await terminationIterator.next() != nil)
        #expect(!channel.yield(try ProviderTestFixture().event(0, .finished)))
        started.continuation.finish()
        termination.continuation.finish()
    }

    @Test func earlyLoopExitCancelsTheLeaseWithoutCancellingTheTask() async throws {
        let cleanupCount = Mutex(0)
        let channel = try ProviderEventChannel(onTermination: { cleanupCount.withLock { $0 += 1 } })
        let fixture = try ProviderTestFixture()
        let first = try fixture.event(0, .running)
        #expect(channel.yield(first))
        let observation = channel.observation
        do {
            defer { observation.cancel() }
            for try await event in observation.events {
                #expect(event == first)
                break
            }
        }
        #expect(!Task.isCancelled)
        #expect(cleanupCount.withLock { $0 } == 1)
        #expect(!channel.yield(try fixture.event(1, .finished)))
        observation.cancel()
        channel.finish()
        #expect(cleanupCount.withLock { $0 } == 1)
    }
}

private struct SyntheticProviderObserver: ProviderSessionObserving {
    let events: [ProviderSessionEvent]
    var failure: ProviderObservationError?
    let observationCapabilities: Set<ProviderObservationCapability> = [.explicitAcceptance, .explicitCompletion]

    func observe(
        _ binding: ProviderSessionBinding
    ) async throws -> ProviderObservation {
        let channel = try ProviderEventChannel()
        guard events.allSatisfy({ $0.binding == binding }) else { throw ProviderObservationError.unavailable }
        for event in events where !channel.yield(event) { throw ProviderObservationError.bufferOverflow }
        channel.finish(throwing: failure)
        return channel.observation
    }
}
