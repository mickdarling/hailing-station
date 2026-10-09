import Foundation
import HailProtocol

/// Tap-to-talk reply references (#230, #365). A phone's final text frame to a plain legacy target (an adapter without
/// contextual delivery, such as `tmux:`) used to be typed with no reply record, so with two devices selecting the
/// same pane its request-less reply was refused `notUniqueRecipient`. The session now mints an opaque reference for
/// that one frame, records it unleased exactly like an ambient reference, and appends a reply footer naming it.
extension HostSession {
    /// The footer appended to tap-to-talk text on a plain legacy target. It shares the ambient reply block's prefix,
    /// command shape and ending; it has no acknowledgement sentence, because the host plays no acknowledgement for
    /// tap-to-talk. ASCII, one line, no double quote: `target` (allowlisted by `isReplySafeTarget`) and the lowercase
    /// UUID (hex and hyphens) are its only variable parts. It is always the last thing typed, so the session's cut
    /// at the LAST ` Reply: answer briefly; ` finds the host's footer, whatever the user's own text says.
    static func tapToTalkReplyFooter(target: String, request: UUID) -> String {
        RightyoInputEvent.replyBlockPrefix + "it is spoken aloud. If no reply bridge publishes this session's output,"
            + " run haild reply " + target + " --request " + request.uuidString.lowercased()
            + " --say '<spoken answer>' (single-quote the answer and keep it free of single quotes; the request"
            + " reference sends it to the device that asked)."
    }

    /// The allowlist a target id must match to be named in a shell-shaped reply instruction:
    /// `[A-Za-z0-9][A-Za-z0-9._:-]{0,95}`, every listed `kind:name` shape and nothing a shell could read as syntax.
    static func isReplySafeTarget(_ target: String) -> Bool {
        let alphanumeric = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        guard let first = target.first, alphanumeric.contains(first), target.count <= 96 else { return false }
        return target.allSatisfy { alphanumeric.contains($0) || "._:-".contains($0) }
    }

    /// The reply owner for one tap-to-talk frame on a legacy target, or nil to deliver it exactly as before (no
    /// footer, no record). The reference is a fresh `UUID()` minted here, in the daemon; nothing in the frame, its
    /// text or any other client input can set or choose it, and a reference the user typed is just text: routing
    /// trusts only this record. The record goes through the same permit, selection generation, capacity and
    /// never-overwrite rules as an ambient reference (`recordOwner`), unleased, pinned to `context`'s binding. Any
    /// failure to form or record it degrades to the unchanged legacy delivery instead of refusing the user's text.
    func tapToTalkOwnership(
        for input: borrowing AuthorizedInput, context: ProviderTurnContext, generation: UUID
    ) async -> HostReplyOwnership? {
        let reference = UUID()
        guard let text = await tapToTalkReferenced(input.text, target: input.target, request: reference) else {
            return nil
        }
        let owner = ProviderTurnContext(id: reference, utteranceID: context.utteranceID,
                                        connectionID: context.connectionID, binding: context.binding)
        guard let permit = await host.replyPublicationPermit(for: owner.binding) else { return nil }
        do {
            try recordOwner(owner, generation: generation, permit: permit, lease: nil)
        } catch {
            return nil
        }
        return HostReplyOwnership(context: owner, contextual: false, text: text)
    }

    /// `text` with the footer appended, or nil when the footer could change what the host decides about the user's
    /// text: an unsafe target id, a result the host's own sanitizer refuses (the phone's character and byte caps
    /// apply to the whole typed line), or a guard rule the footer would newly trigger under the policy in force.
    /// The footer never turns a deliverable utterance into a refused or confirmation-required one.
    private func tapToTalkReferenced(_ text: String, target: String, request: UUID) async -> String? {
        guard Self.isReplySafeTarget(target) else { return nil }
        let referenced = text + Self.tapToTalkReplyFooter(target: target, request: request)
        let policy = host.sanitizing
        guard let plain = try? Sanitizer.sanitize(text, policy: policy),
              let lines = try? Sanitizer.sanitize(referenced, policy: policy),
              let guards = try? CompiledGuards(await host.currentPolicy.guardPatterns),
              Set(guards.matches(in: lines)).isSubset(of: guards.matches(in: plain)) else { return nil }
        return referenced
    }
}
