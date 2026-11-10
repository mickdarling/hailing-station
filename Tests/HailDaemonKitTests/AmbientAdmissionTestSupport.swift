#if os(macOS)
import Foundation
@testable import HailDaemonKit

extension AmbientAudioEvent {
    static func admittedStart(
        stream: UUID, connection: UUID, target: String, selection: UUID? = nil, binding: String,
        policy: TargetPolicyGeneration
    ) -> Self {
        .started(stream: stream, connection: connection,
                 scope: AmbientStreamScope(target: target, selection: selection, binding: binding,
                                           policyGeneration: policy))
    }
}

extension AmbientWiringRig {
    var admissionPolicy: TargetPolicyGeneration {
        rig.host.targetPolicy.snapshot(for: RecipientTestRig.target)
    }
}
#endif
