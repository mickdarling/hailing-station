import Foundation
import Testing
@testable import HailCore

@MainActor private final class CapturePermissionProbe {
    var requested = false
    private var hasResult = false
    private var result = false
    private var waiter: CheckedContinuation<Bool, Never>?
    func request() async -> Bool {
        requested = true
        if hasResult { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
    func complete(_ granted: Bool) {
        result = granted
        hasResult = true
        waiter?.resume(returning: granted)
        waiter = nil
    }
}

@Suite @MainActor struct CapturePermissionAdmissionTests {
    @Test func unavailableAdmissionNeverRequestsPermissionsOrConstructsCapture() async {
        var reserved = 0, permissions = 0, released = 0, constructed = 0
        let allowed = await CapturePermissionAdmission.request(
            mayBegin: { false }, reserve: { reserved += 1 },
            permissions: { permissions += 1; return true }, release: { released += 1 }
        )
        if allowed { constructed += 1 }
        #expect(!allowed && reserved == 0 && permissions == 0 && released == 0 && constructed == 0)
    }

    @Test(arguments: [false, true]) func permissionResultRetainsOrReleasesItsOwnReservation(granted: Bool) async {
        let exclusion = CoachingCaptureExclusion(), owner = UUID(), competitor = UUID()
        var availabilityReads = 0, permissions = 0, constructed = 0
        let allowed = await CapturePermissionAdmission.request(
            mayBegin: { availabilityReads += 1; return !exclusion.isClaimed },
            reserve: { #expect(exclusion.claim(owner)) }, permissions: {
                permissions += 1
                #expect(exclusion.isClaimed && !exclusion.claim(competitor))
                return granted
            }, release: { exclusion.release(owner) }
        )
        if allowed { constructed += 1 }
        #expect(allowed == granted && availabilityReads == 1 && permissions == 1)
        #expect(constructed == (granted ? 1 : 0) && exclusion.isClaimed == granted)
        exclusion.release(owner)
        #expect(exclusion.claim(competitor))
        exclusion.release(owner) // An old completion cannot release a successor.
        #expect(exclusion.isClaimed)
        exclusion.release(competitor)
    }

    @Test func cancellationWhilePermissionIsPendingCannotStartCaptureOrReleaseACompetitor() async throws {
        let exclusion = CoachingCaptureExclusion(), owner = UUID(), competitor = UUID()
        let probe = CapturePermissionProbe()
        var constructed = 0
        let task = Task {
            let allowed = await CapturePermissionAdmission.request(
                mayBegin: { !exclusion.isClaimed }, reserve: { #expect(exclusion.claim(owner)) },
                permissions: { await probe.request() }, release: { exclusion.release(owner) }
            )
            if allowed { constructed += 1 }
            return allowed
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !probe.requested, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let reachedWait = probe.requested
        task.cancel()
        #expect(exclusion.isClaimed && !exclusion.claim(competitor))
        probe.complete(true)
        let allowed = await task.value
        try #require(reachedWait, "permission fixture did not reach its owned wait")
        #expect(!allowed && constructed == 0 && !exclusion.isClaimed)
        #expect(exclusion.claim(competitor))
        exclusion.release(owner)
        #expect(exclusion.isClaimed)
        exclusion.release(competitor)
    }

    @Test func alreadyCancelledStartNeverAcquiresAdmissionOrRequestsPermissions() async {
        var availability = 0, reserved = 0, permissions = 0, released = 0
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CapturePermissionAdmission.request(
                mayBegin: { availability += 1; return true }, reserve: { reserved += 1 },
                permissions: { permissions += 1; return true }, release: { released += 1 }
            )
        }
        #expect(await task.value == false)
        #expect(availability == 0 && reserved == 0 && permissions == 0 && released == 0)
    }
}
