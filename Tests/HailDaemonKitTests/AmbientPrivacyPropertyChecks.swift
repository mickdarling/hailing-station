#if os(macOS)
import Foundation
@testable import HailDaemonKit

/// The invariants over the ordered clip sequence, after the bound (#735 S-8 HS-C round 4).
extension AmbientPrivacyPropertyTests {
    static func check(_ world: PrivacySimWorld) -> [String] {
        var failures: [String] = []
        let clips = world.played
        for entry in 1...max(1, world.ledger.last) where world.ledger.last > 0 {
            let said = clips.filter { $0 == .on(entry) || $0 == .unavailable(entry) || $0 == .silent(entry) }
            if said.count != 1 { failures.append("entry \(entry) played \(said.count) clips") }
            guard let index = clips.firstIndex(where: { $0 == .on(entry) || $0 == .unavailable(entry) }) else {
                failures += supersededIsAnswered(entry, in: world)
                continue
            }
            if index == 0 || clips[index - 1] != .stop(entry) {
                failures.append("entry \(entry) clip without its stop")
            }
            if clips[index] == .on(entry) { failures += refusalsAfter(entry, at: index, in: world) }
        }
        for child in world.children where child.killed {
            guard case .refused? = child.duck.settled else { continue }
            let accounted = child.said + child.claimed + child.carried + child.silenced
            if accounted != 1 {
                failures.append("child \(child.index) refusal accounted \(accounted) times (said \(child.said), "
                    + "claimed \(child.claimed), carried \(child.carried), silenced \(child.silenced))")
            }
        }
        return failures + lastClipMatches(world) + recoveryAndOff(world)
    }

    /// The privacy state each played clip leaves, in order (nil for a stop or a silence).
    static func states(_ world: PrivacySimWorld) -> [(PrivacySimClip, AmbientPrivacySaid)] {
        world.played.compactMap { clip in
            switch clip {
            case .on: (clip, .on)
            case .unavailable, .own: (clip, .unavailable)
            case .off, .offNotice: (clip, .off)
            default: nil
            }
        }
    }

    /// No flapping: a recovery entry's "privacy on" follows an "unavailable" directly, so there is at most one per
    /// unavailable-to-on transition. After an off: once the last "Recording again." plays with privacy off at the end,
    /// nothing after it says "privacy on" or "unavailable".
    static func recoveryAndOff(_ world: PrivacySimWorld) -> [String] {
        let said = states(world)
        var failures: [String] = []
        for (index, (clip, _)) in said.enumerated() {
            guard case .on(let entry) = clip, world.recoveries.contains(entry) else { continue }
            if index == 0 || said[index - 1].1 != .unavailable {
                failures.append("recovery entry \(entry) said privacy on without an unavailable before it")
            }
        }
        if !world.on, let last = said.lastIndex(where: { $0.1 == .off }), last < said.count - 1 {
            failures.append("after the last off, \(said[(last + 1)...].map(\.1)) while privacy stays off")
        }
        return failures
    }

    /// An entry silent as superseded by a newer one is answered by a later entry's clip, or by an off.
    static func supersededIsAnswered(_ entry: Int, in world: PrivacySimWorld) -> [String] {
        guard world.decided[entry]?.tokens.contains("superseded_by_newer") == true,
              let index = world.played.firstIndex(of: .silent(entry)) else { return [] }
        let answered = world.played[(index + 1)...].contains { clip in
            switch clip {
            case .on(let later), .unavailable(let later): later > entry
            case .off, .offNotice: true
            default: false
            }
        }
        return answered ? [] : ["entry \(entry) superseded, and no newer entry or off answered it"]
    }

    /// A refusal said after entry `entry`'s "privacy on" must be one decided after its close (or of a child it never
    /// counted): an earlier one would leave "privacy on" claiming what that refusal already undid.
    static func refusalsAfter(_ entry: Int, at index: Int, in world: PrivacySimWorld) -> [String] {
        guard let decision = world.decided[entry] else { return [] }
        return world.played[(index + 1)...].compactMap { clip in
            guard case .own(let child) = clip, child >= 0 else { return nil }
            let refused = world.children[child]
            guard refused.refusedTick < decision.tick, decision.members.contains(where: { $0 === refused }) else {
                return nil
            }
            return "entry \(entry)'s privacy on outlived child \(child)'s earlier refusal"
        }
    }

    /// (b) The last privacy clip matches the final state: off is "Recording again." (or the device notice for an off
    /// no child took); on with every listening child proven is "privacy on"; on with a listening child not proven is
    /// "unavailable". With nothing listening, nothing is claimed either way.
    static func lastClipMatches(_ world: PrivacySimWorld) -> [String] {
        let states = world.played.compactMap { clip -> AmbientPrivacySaid? in
            switch clip {
            case .on: .on
            case .unavailable, .own: .unavailable
            case .off, .offNotice: .off
            default: nil
            }
        }
        guard let last = states.last else { return [] }
        let expected: AmbientPrivacySaid
        if !world.on {
            expected = .off
        } else if world.hearing.isEmpty {
            return []
        } else {
            expected = world.hearing.allSatisfy { $0.duck.settled == .kept } ? .on : .unavailable
        }
        return last == expected ? [] : ["the last privacy clip says \(last), the state is \(expected)"]
    }
}
#endif
