import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
struct AmbientRefusalPolicyTests {
    @Test func policyStopRequiresCodeAndExactWirePrefix() {
        let messages = [
            "ambient target_policy_changed", "ambient target_policy_changed extra",
            "ambient target is not allowed", "ambient target is not allowed — run haild targets allow on the Mac",
            "ambient stopped: synthetic", "ambient unavailable: synthetic", "ambient target is not selected",
            "ambient moved to pad", "target_policy_changed", " ambient target_policy_changed", ""
        ]
        let codes: [ErrorCode] = [.notAllowed, .unauthorized, .malformed, .rateLimited, .unknown("not_allowed")]
        for code in codes {
            for (index, message) in messages.enumerated() {
                #expect(AmbientRefusal.isPolicyStop(code: code, message: message) == (code == .notAllowed && index < 4))
            }
        }
    }

    @Test func remoteFailureAdapterUsesTheSamePredicate() {
        #expect(AmbientRefusal.isPolicyStop(HostConnectionFailure.remote("not_allowed: ambient target_policy_changed")))
        #expect(AmbientRefusal.isPolicyStop(HostConnectionFailure.remote("not_allowed: ambient target is not allowed")))
        #expect(!AmbientRefusal.isPolicyStop(HostConnectionFailure.remote("malformed: ambient target_policy_changed")))
        #expect(!AmbientRefusal.isPolicyStop(HostConnectionFailure.remote("not_allowed: ambient stopped: synthetic")))
        #expect(!AmbientRefusal.isPolicyStop(
            HostConnectionFailure.remote("not_allowed: ambient unavailable: synthetic")
        ))
        #expect(!AmbientRefusal.isPolicyStop(HostConnectionFailure.notReady))
        #expect(AmbientListeningController.isTransient(
            HostConnectionFailure.remote("not_allowed: ambient unavailable: synthetic")
        ))
    }
}
