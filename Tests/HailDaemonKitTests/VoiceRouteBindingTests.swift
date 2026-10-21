#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// A voice route's binding for ambient addressing (#636, second-key review on #707): only a listed, alive route at the
/// binding its policy allows has one. Synthetic only: a fake tmux adapter.
@Suite struct VoiceRouteBindingTests {
    @Test func onlyAListedAliveRouteAtItsPolicyBindingHasOne() async throws {
        let rig = try await VoiceRouteRig.make()
        #expect(await rig.listener.voiceRouteBinding(VoiceRouteRig.deck) == "d")
        // Not listed (no such pane), and listed but with no policy entry.
        #expect(await rig.listener.voiceRouteBinding("tmux:voice") == nil)
        #expect(await rig.listener.voiceRouteBinding("tmux:rogue") == nil)
        // Rebound: the pane behind the name changed since the policy allowed it.
        await rig.adapter.setTargets([AdapterTarget(name: "scratch", binding: "s"),
                                      AdapterTarget(name: "deck", binding: "d2")])
        #expect(await rig.listener.voiceRouteBinding(VoiceRouteRig.deck) == nil)
        // Listed at its binding, but not alive.
        await rig.adapter.setTargets([AdapterTarget(name: "scratch", binding: "s"),
                                      AdapterTarget(name: "deck", alive: false, binding: "d")])
        #expect(await rig.listener.voiceRouteBinding(VoiceRouteRig.deck) == nil)
        #expect(await rig.listener.voiceRouteBinding(VoiceRouteRig.scratch) == "s")
    }
}
#endif
