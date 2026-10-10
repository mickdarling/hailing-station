#if os(macOS)
import Foundation

/// The spoken confirmation of the owner's stop (#418): a short host-recorded clip, sent like an acknowledgement to the
/// connection that said stop, with no round trip through the agent session. Clips live in reserved folders of the
/// acknowledgement directory: `confirm-stopped/` ("Stopped.") and `confirm-idle/` ("Nothing playing, standing by.").
/// A later mute (#404) adds its own folder here.
enum AmbientStopConfirmation {
    static let stopped = RightyoAddressing.key("confirm-stopped"), idle = RightyoAddressing.key("confirm-idle")

    /// The clip folder for a playback stop, or nil when nothing is confirmed: a dismissal that does not stop playback,
    /// one not from the enrolled owner, or one whose connection is gone. `idle` means the host had no reply in flight
    /// and sent no `stop_playback`; a phone that takes `stop_playback` always reports `stopped`, since only it knows
    /// whether audio was still playing.
    static func persona(for receipt: RightyoDismissReceipt, playback: String) -> String? {
        guard receipt.stopsPlayback, receipt.owner, playback != "no_connection" else { return nil }
        return playback == "idle" ? idle : stopped
    }

    /// A chosen confirmation clip and the folder and index it came from, for the log.
    struct Pick: Equatable {
        let persona: String, index: Int, clip: AmbientAckClip
    }

    /// The next clip for `persona`; an idle stop without its own clips says "Stopped." instead.
    static func clip(_ persona: String, in library: AmbientAckLibrary) -> Pick? {
        for candidate in persona == idle ? [idle, stopped] : [persona] {
            if let (index, clip) = library.next(for: candidate) {
                return Pick(persona: candidate, index: index, clip: clip)
            }
        }
        return nil
    }
}
#endif
