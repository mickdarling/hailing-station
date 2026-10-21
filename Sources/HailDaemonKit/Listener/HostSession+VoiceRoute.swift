import Foundation
import HailProtocol

/// Voice routing (#636): a device that selects one of the owner's routes can send a single request to another
/// route by naming it first ("Deck, add a slide"), and keeps its selection. The routed request is the device's
/// input to that route, so its reply comes back to this device as any reply does; a request reference still
/// routes exactly. Nothing falls back: an offline, unclear or empty address sends nothing and says so.
///
/// Tap-to-talk has no speaker identity, so the device holding the connection is treated as the owner here, exactly
/// as for `select`. A route only names a target. Each one still needs its own policy entry and binding, and every
/// existing gate (shape, sanitizer, paste, policy, tier, lockdown, binding) applies to the routed frame as to any
/// other.
extension HostSession {
    /// One host-made route: input selected on `from` is being handed to `to`. A tap route also carries the selection
    /// generation it was made on, so it admits nothing on any later selection, even of the same target.
    struct VoiceRouted: Sendable, Equatable {
        let from: String
        let to: String
        var generation: UUID?
    }

    /// The route this one ingress is being handed to, bound only while the host delivers a frame it routed itself
    /// (`voiceRoute`) or the listener dispatches an ambient request its consumer routed. No frame field, device name
    /// or local socket request can set it, and it admits nothing once the selection has moved off `from`.
    @TaskLocal static var voiceRouted: VoiceRouted?

    enum VoiceRouting {
        /// Deliver this frame; `routed` names the route when the host rewrote its target.
        case deliver(Frame, routed: VoiceRouted?)
        case refused(ErrorCode, String)
    }

    /// The selection covers `target`: it is the selected target, or both it and the selected target are routes in the
    /// owner's file. Records, generations and replies use this; input itself needs `admitsInput`.
    func covers(_ target: String) -> Bool {
        guard let selectedTarget else { return false }
        if selectedTarget == target { return true }
        #if os(macOS)
        guard let routes = authorizer.voiceRoutes else { return false }
        return routes.route(for: selectedTarget) != nil && routes.route(for: target) != nil
        #else
        return false
        #endif
    }

    /// Input goes to the selected target; host-routed input goes only to its route, and only while its origin is still
    /// exactly what is selected, on the generation it was routed on when it carries one. So input routed from a stream
    /// on Scratch is refused once Deck is selected, even when Deck was its route: it belonged to an ended selection.
    func admitsInput(to target: String) -> Bool {
        guard let routed = Self.voiceRouted else { return target == selectedTarget }
        return routed.to == target && routed.from == selectedTarget && covers(target)
            && (routed.generation ?? selectionGeneration) == selectionGeneration
    }

    /// A device's final text frame to its selected route, opening with another route's name, is addressed to that
    /// route: only its target changes, and the text goes as heard. The authorizer judges the frame first, so a frame
    /// it would refuse meets that refusal rather than any route answer. A route that is not listed, allowed, bound and
    /// alive refuses; so do another route's name with nothing after it (unless a paste goes with it) and a near miss.
    /// The selected route's own name alone goes to it, as before routing. During lockdown nothing is routed, so the
    /// frame meets the lockdown refusal as it is. Every other frame is untouched.
    func voiceRoute(_ frame: Frame) async -> VoiceRouting {
        #if os(macOS)
        guard let routes = authorizer.voiceRoutes, case .text(let text) = frame.payload, text.isFinal,
              text.reply == nil, let target = frame.target, target == selectedTarget,
              routes.route(for: target) != nil, await authorizer.authorize(frame) == .allow,
              await !host.lockdown.isOn else { return .deliver(frame, routed: nil) }
        let named: VoiceRoutes.Route
        switch routes.match(text.text) {
        case .unaddressed:
            return .deliver(frame, routed: nil)
        case .routed(let route, _):
            named = route
        case .nothingToSay(let route) where text.pasted != nil || route.target == target:
            named = route
        case .nothingToSay(let route):
            return .refused(.malformed, "voice route: nothing to send to \(route.name)")
        case .unclear:
            return .refused(.notAllowed, "voice route: which session? Nothing was sent")
        }
        guard named.target != target else { return .deliver(frame, routed: nil) }
        // A policy that cannot be read lists nothing; that is not the route being offline.
        guard await host.refreshedPolicy() != nil, let listed = try? await policyFilteredTargets() else {
            return .refused(.malformed, "voice route: the target list is unavailable; nothing was sent")
        }
        guard listed.contains(where: { $0.id == named.target && $0.alive }) else {
            return .refused(.unknownTarget, "voice route: \(named.name) is offline; nothing was sent")
        }
        var routed = frame
        routed.target = named.target
        return .deliver(routed, routed: VoiceRouted(from: target, to: named.target, generation: selectionGeneration))
        #else
        return .deliver(frame, routed: nil)
        #endif
    }
}
