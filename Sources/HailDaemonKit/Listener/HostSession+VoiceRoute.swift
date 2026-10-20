import Foundation
import HailProtocol

/// Voice routing (#636): a device that selects one of the owner's routes can send a single request to another
/// route by naming it first ("Deck, add a slide"), and keeps its selection. The routed request is the device's
/// input to that route, so its reply comes back to this device as any reply does; a request reference still
/// routes exactly. Nothing falls back: an offline, unclear or empty address sends nothing and says so.
///
/// Tap-to-talk has no speaker identity, so the device holding the connection is treated as the owner here, exactly
/// as for `select`. A route only names a target. Each one still needs its own policy entry and binding, and every
/// existing gate (shape, sanitizer, paste, policy, tier, binding) applies to the routed frame as to any other.
extension HostSession {
    /// The route this one ingress is being handed to, bound only while the host delivers a frame it rewrote itself
    /// (`voiceRoute`). No frame field, device name or local socket request can set it.
    @TaskLocal static var voiceRoutedTarget: String?

    enum VoiceRouting {
        /// Deliver this frame; `routedTo` names the route when the host rewrote its target.
        case deliver(Frame, routedTo: String?)
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

    /// Input may go to the selected target, or to the route the host voice-routed this very frame to.
    func admitsInput(to target: String) -> Bool {
        target == selectedTarget || (target == Self.voiceRoutedTarget && covers(target))
    }

    /// A device's final text frame to its selected route, opening with another route's name, is addressed to that
    /// route: only its target changes, and the text goes as heard. A route that is not listed, allowed, bound and
    /// alive refuses; so do a name with nothing after it and a near miss. Every other frame is untouched.
    func voiceRoute(_ frame: Frame) async -> VoiceRouting {
        #if os(macOS)
        guard let routes = authorizer.voiceRoutes, case .text(let text) = frame.payload, text.isFinal,
              text.reply == nil, let target = frame.target, target == selectedTarget,
              routes.route(for: target) != nil else { return .deliver(frame, routedTo: nil) }
        switch routes.match(text.text) {
        case .unaddressed:
            return .deliver(frame, routedTo: nil)
        case .routed(let route, _) where route.target == target:
            return .deliver(frame, routedTo: nil)
        case .routed(let route, _):
            let online = try? await policyFilteredTargets().contains { $0.id == route.target && $0.alive }
            guard online == true else {
                return .refused(.unknownTarget, "voice route: \(route.name) is offline; nothing was sent")
            }
            var routed = frame
            routed.target = route.target
            return .deliver(routed, routedTo: route.target)
        case .nothingToSay(let route):
            return .refused(.malformed, "voice route: nothing to send to \(route.name)")
        case .unclear:
            return .refused(.notAllowed, "voice route: which session? Nothing was sent")
        }
        #else
        return .deliver(frame, routedTo: nil)
        #endif
    }
}
