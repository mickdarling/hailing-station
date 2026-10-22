public import Foundation
import HailProtocol
import Synchronization

// The delivery-step protocol and its direct implementation stay beside the consumer that owns their contract.
// swiftlint:disable file_length

/// What an admitted RightyO request becomes once delivered (#188 item 1, part B). `request` is the host-minted
/// reply request the named connection now owns, or nil when no reply ownership was established: the direct
/// `HailHost.send` path never mints one, and a dispatch to a legacy adapter answers `request: null`.
public struct RightyoDispatchReceipt: Sendable, Equatable {
    public var request: UUID?
    /// The deliverer's own explanation when the prompt landed but no reply ownership survived (for example
    /// the daemon's `ownershipLost` or `connectionLost`); nil when there is nothing to explain.
    public var caveat: String?
    public init(request: UUID?, caveat: String? = nil) {
        self.request = request
        self.caveat = caveat
    }
}
/// What one admitted `dismiss` did (rightyo#98). Fixed tokens and counts only: never ids or transcript text.
public struct RightyoDismissReceipt: Sendable, Equatable {
    /// `stop-phrase` or `decision`.
    public var reason: String
    /// What RightyO asks the host to stop: `playback`, `pending_request`, `engagement`.
    public var scope: [String]
    /// Listed ids this consumer never delivered: dropped should they ever arrive. RightyO already withholds
    /// them, so this is the host's own record, not a delivery change.
    public var withdrawn: Int
    /// Listed ids already delivered: withdrawal is advisory and nothing delivered is undone.
    public var alreadyDelivered: Int
    /// The dismissal came from the enrolled owner (#418): it said `owner`, which RightyO may only say on an enrolled
    /// session, and so did the transcript it cites, as for a supersede.
    public var owner: Bool
    public var stopsPlayback: Bool { scope.contains("playback") }
    public init(reason: String, scope: [String], withdrawn: Int, alreadyDelivered: Int, owner: Bool = false) {
        (self.reason, self.scope, self.withdrawn, self.alreadyDelivered) = (reason, scope, withdrawn, alreadyDelivered)
        self.owner = owner
    }
}
/// The owner's spoken mute (#404): a whole turn that is only a mute or unmute phrase, optionally after a greeting, one
/// of the session's addressing names ("Jarvis") and "please", and with any punctuation. Anything longer, any other
/// leading word ("press mute", "let's talk again") or a negation ("don't mute") is not one: it goes to the agent as a
/// request. Matched on the heard words only; nothing is logged.
/// On an anonymous (not enrolled) session any voice the mic hears can say it. That is accepted because the mute only
/// silences reply audio on the device that heard it, and is undone by "unmute", the app's toggle or a relaunch.
enum VoiceMute {
    static let mutePhrases: Set<String> = ["mute", "go quiet", "text only", "mute replies"]
    static let unmutePhrases: Set<String> = ["unmute", "you can talk again", "talk again", "unmute replies"]
    static let greetings: Set<String> = ["hey", "ok", "okay"]

    enum Command: Sendable { case mute, unmute }

    /// The keyed spellings of the names RightyO advertised in `started` (`addressing`, rightyo#105), the same names
    /// that pick the acknowledgement voice; none when it advertised none.
    static func names(in addressing: JSONValue?) -> Set<String> {
        #if os(macOS)
        Set(RightyoAddressing(addressing).spellings.values.joined().map(RightyoAddressing.key))
        #else
        []
        #endif
    }

    /// The command a whole turn says, given the session's keyed addressing `names`; nil for anything else.
    static func command(in heard: String, names: Set<String>) -> Command? {
        var words = heard.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        while words.last == "please" { words.removeLast() }
        for candidate in candidates(words, names: names) {
            let phrase = candidate.joined(separator: " ")
            if mutePhrases.contains(phrase) { return .mute }
            if unmutePhrases.contains(phrase) { return .unmute }
        }
        return nil
    }

    /// The turn as said, and with its leading greeting, addressing name (up to three words, as recognition may split
    /// "Righty O") and "please" taken off in turn.
    static func candidates(_ words: [String], names: Set<String>) -> [ArraySlice<String>] {
        var rest = words[...], found = [rest]
        if let first = rest.first, greetings.contains(first) { rest = rest.dropFirst(); found.append(rest) }
        if let named = nameWidth(rest, names: names) {
            rest = rest.dropFirst(named)
            found.append(rest)
        }
        if rest.first == "please" { found.append(rest.dropFirst()) }
        return found
    }

    /// How many leading words of `rest` (up to three) spell one of the keyed `names`, leaving at least one word after.
    static func nameWidth(_ rest: ArraySlice<String>, names: Set<String>) -> Int? {
        (1...3).first { width in
            width < rest.count && names.contains(String(rest.prefix(width).joined().filter { $0 != "'" }))
        }
    }
}

/// The owner's spoken media mode (#551): a whole turn that is only an on or off phrase, trimmed as `VoiceMute` trims.
/// While it is on, RightyO attends only to the owner's voice naming the assistant (rightyo#195), so the off phrase
/// needs the name ("Jarvis, done watching"). Matched on the heard words only; nothing is logged.
enum VoiceMedia {
    enum Command: Sendable { case on, off }

    static let onPhrases: Set<String> = [
        "media mode", "media mode on", "watching tv", "i'm watching tv", "i'm going to watch tv",
        "i'm watching a movie", "i'm watching a video", "putting a video on"
    ]
    static let offPhrases: Set<String> = [
        "media mode off", "end media mode", "done watching", "i'm done watching", "tv's off", "the tv's off"
    ]

    /// The command a whole turn says, given the session's keyed addressing `names`; nil for anything else.
    static func command(in heard: String, names: Set<String>) -> Command? {
        var words = heard.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        while words.last == "please" { words.removeLast() }
        for candidate in VoiceMute.candidates(words, names: names) {
            let phrase = candidate.joined(separator: " ")
            if onPhrases.contains(phrase) { return .on }
            if offPhrases.contains(phrase) { return .off }
        }
        return nil
    }
}

/// What privacy mode (#735, internally duck) asks the host to do. `enter` is a safety-set entry command
/// (`PrivacyEntry`) in the live enrolled owner's turn, and `stillRecording` a negated one ("don't stop recording"), which only plays
/// "Still recording."; `exit` and `status` are RightyO's content-free `privacy` events (rightyo S-1), which RightyO
/// matched itself while private, when the host hears no words at all. `lost` is privacy ended because a reloaded child
/// cannot keep it; `refused` an entry phrase from anyone but the live enrolled owner.
public enum PrivacyCommand: Sendable, Equatable { case enter, stillRecording, exit, status, lost, refused }

/// The privacy safety set's entry (#735 S-2): deterministic and local, with no model, and intentional only (Mick,
/// round 2: "It needs to be really intentional"). An entry phrase counts only as a standalone command: the whole turn,
/// or the whole turn after a leading greeting and assistant name ("Hey Jarvis, privacy mode."), with fillers and
/// politeness at the edges only ("ok", "um", "so", "please", "now", "thanks"), in any case and with any punctuation.
/// The commands are "privacy mode" (also "privacy mode on", "turn on", "enter" or "start privacy mode"), "go
/// private", and "stop" with "recording", "recordings" or "listening", up to two determiners between ("stop the
/// recording", "stop all the recordings"), and "stop listening to me".
///
/// Nothing embedded counts: a phrase mid-sentence ("we should go private"), with an object after it ("stop listening
/// on 443", "go private on github"), asked about ("what is privacy mode?") or said as a question ("stop recording?").
/// A standalone negated command ("don't stop recording", "please do not go private") is `negated`: "Still
/// recording.". A lone name is no command, so a name said alone and the command in the next turn enters on the second.
/// Who may say it is the consumer's rule (`privacyCommand`: the live enrolled owner only). Matched on the heard words
/// only; nothing is logged.
enum PrivacyEntry {
    enum Match: Sendable, Equatable { case enter, negated }

    static let leading: Set<String> = ["ok", "okay", "um", "uh", "so", "please", "hey", "now"]
    static let trailing: Set<String> = ["please", "now", "thanks", "ok", "okay", "um", "uh"]
    static let negations: [[String]] = [["don't"], ["dont"], ["do", "not"], ["never"]]
    /// Words before a leading comma that are not an assistant's name: a command's own start, or an interjection.
    static let interjections: Set<String> = [
        "stop", "go", "privacy", "turn", "enter", "start", "don't", "dont", "do", "never", "no", "not", "yes", "yeah",
        "well", "fine", "wait", "right", "oh", "and", "but", "look", "listen", "actually", "alright", "sure"
    ]
    static let determiners: Set<String> = ["the", "all", "any", "your", "my", "our", "this", "that", "these", "those"]
    static let stopped: Set<String> = ["recording", "recordings", "listening"]
    static let commands: Set<[String]> = [
        ["privacy", "mode"], ["privacy", "mode", "on"], ["turn", "on", "privacy", "mode"],
        ["enter", "privacy", "mode"], ["start", "privacy", "mode"], ["go", "private"]
    ]

    /// What the whole turn `heard` says, given the session's keyed addressing `names`; nil for anything else.
    static func match(_ heard: String, names: Set<String> = []) -> Match? {
        guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else { return nil }
        var words = trimmed(heard, names: names)
        let negation = negations.first { words.starts(with: $0) }
        if let negation { words.removeFirst(negation.count) }
        words = Array(words.drop { leading.contains($0) })
        guard isCommand(words) else { return nil }
        return negation == nil ? .enter : .negated
    }

    /// The turn's words with edge fillers and politeness, a leading greeting, and an assistant name at either end
    /// taken off: one of `names`, or a single word set off by a comma at the start ("Computer, stop recording.").
    static func trimmed(_ heard: String, names: Set<String>) -> [String] {
        var words = words(heard)[...]
        words = words.drop { leading.contains($0) }
        if let named = VoiceMute.nameWidth(words, names: names) {
            words = words.dropFirst(named)
        } else if words.count > 1, let address = addressed(heard), address == words.first {
            words = words.dropFirst()
        }
        words = words.drop { leading.contains($0) }
        for _ in 0..<2 {
            while let last = words.last, trailing.contains(last) { words = words.dropLast() }
            if words.suffix(2) == ["thank", "you"] { words = words.dropLast(2) }
            if let width = (1...3).first(where: { width in
                width < words.count && names.contains(words.suffix(width).joined().filter { $0 != "'" })
            }) { words = words.dropLast(width) }
        }
        return Array(words)
    }

    /// The single word before the turn's first comma, fillers aside, unless it could start a command.
    static func addressed(_ heard: String) -> String? {
        guard let comma = heard.firstIndex(of: ",") else { return nil }
        let before = words(String(heard[..<comma])).drop { leading.contains($0) }
        guard before.count == 1, let word = before.first,
              !interjections.contains(word) else { return nil }
        return word
    }

    /// Whether `words` are exactly one command.
    static func isCommand(_ words: [String]) -> Bool {
        if commands.contains(words) { return true }
        guard words.first == "stop" else { return false }
        var index = 1
        while index <= 2, index < words.count - 1, determiners.contains(words[index]) { index += 1 }
        guard index < words.count, stopped.contains(words[index]) else { return false }
        let rest = Array(words[(index + 1)...])
        return rest.isEmpty || (words[index] == "listening" && rest == ["to", "me"])
    }

    /// Lower-cased letter runs, apostrophes kept inside a word ("don't", typographic or not) and trimmed off its ends.
    static func words(_ heard: String) -> [String] {
        heard.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !$0.isLetter && $0 != "'" }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}

#if os(macOS)
/// The spoken confirmation of the owner's stop (#418): a short host-recorded clip, sent like an acknowledgement to the
/// connection that said stop, with no round trip through the agent session. Clips live in reserved folders of the
/// acknowledgement directory: `confirm-stopped/` ("Stopped.") and `confirm-idle/` ("Nothing playing, standing by."),
/// for the owner's spoken mute (#404) `confirm-muted/` ("Muted.") and `confirm-unmuted/` ("Unmuted."), and for media
/// mode (#551) `confirm-media-on/` and `confirm-media-off/`, for spoken notes (#552) `confirm-saved/` and
/// `confirm-not-saved/`, and for privacy mode (#735, internally duck) `confirm-privacy-on/`, `confirm-privacy-off/`,
/// `confirm-privacy-status/` and `confirm-still-recording/`.
enum AmbientStopConfirmation {
    static let stopped = RightyoAddressing.key("confirm-stopped"), idle = RightyoAddressing.key("confirm-idle")
    static let muted = RightyoAddressing.key("confirm-muted"), unmuted = RightyoAddressing.key("confirm-unmuted")
    /// Media mode (#551): "Media mode on." and "Media mode off."
    static let mediaOn = RightyoAddressing.key("confirm-media-on")
    static let mediaOff = RightyoAddressing.key("confirm-media-off")
    /// A spoken note (#552): "Saved." once its Shortcut succeeded, "That didn't save." when it did not.
    static let saved = RightyoAddressing.key("confirm-saved"), notSaved = RightyoAddressing.key("confirm-not-saved")
    /// An ambient request the owner addressed to a voice route that did not take it (#636): "Nothing was sent."
    static let notSent = RightyoAddressing.key("confirm-not-sent")
    /// Privacy mode (#735, internally duck): `confirm-privacy-on/` ("Privacy on. I'm only listening for my name.") is
    /// worded as a status, since it also answers an entry said while privacy is already on; `confirm-privacy-off/`
    /// ("Recording again."); `confirm-privacy-status/` answers RightyO's status event while private, and
    /// `confirm-still-recording/` ("Still recording.") a negated entry. A folder Mick has not recorded plays nothing.
    /// None may contain an exit phrase ("I'm back", "start listening", "privacy off"): the microphone hears them.
    static let privacyOn = RightyoAddressing.key("confirm-privacy-on")
    static let privacyOff = RightyoAddressing.key("confirm-privacy-off")
    static let privacyStatus = RightyoAddressing.key("confirm-privacy-status")
    static let stillRecording = RightyoAddressing.key("confirm-still-recording")
    static let reserved: Set<String> = [stopped, idle, muted, unmuted, mediaOn, mediaOff, saved, notSaved, notSent,
                                        privacyOn, privacyOff, privacyStatus, stillRecording]

    /// Why a playback stop is not confirmed, as a log token, or nil when it is: only the enrolled owner's stop, and
    /// only on a connection still there to hear it.
    static func skipReason(for receipt: RightyoDismissReceipt, playback: String) -> String? {
        if !receipt.owner { return "not_owner" }
        return playback == "no_connection" ? "no_connection" : nil
    }

    /// The clip folder for a playback stop, or nil when nothing is confirmed (see `skipReason`). `idle` means the
    /// host had no reply in flight and sent no `stop_playback`; a phone that takes `stop_playback` always reports
    /// `stopped`, since only it knows whether audio was still playing (#442).
    static func persona(for receipt: RightyoDismissReceipt, playback: String) -> String? {
        guard receipt.stopsPlayback, skipReason(for: receipt, playback: playback) == nil else { return nil }
        return playback == "idle" ? idle : stopped
    }

    /// A chosen confirmation clip and the folder and index it came from, for the log.
    struct Pick: Equatable {
        let persona: String, index: Int, clip: AmbientAckClip
    }

    /// The next clip for `persona`; an idle stop without its own clips says "Stopped." instead.
    static func clip(_ persona: String, in library: AmbientAckLibrary) -> Pick? {
        for candidate in persona == idle ? [idle, stopped] : [persona] {
            if let (index, clip) = library.nextReserved(candidate) {
                return Pick(persona: candidate, index: index, clip: clip)
            }
        }
        return nil
    }
}

extension AmbientAckLibrary {
    /// No persona and no confirmation clip: acknowledgements stay off. Confirmation clips alone keep the library, for
    /// stop confirmations without any persona (#418).
    var isEmpty: Bool { clips.isEmpty && reserved.isEmpty }
    /// The `ambient_ack_clips` startup detail: counts only.
    var summary: String {
        "personas=\(clips.count) clips=\(clips.values.map(\.count).reduce(0, +)) reserved=\(reserved.count)"
    }
}

/// Host clip phrases this host sent (#418, "Stopped."): heard back word for word they are echo, however short, until
/// `RecentSpokenReplies.hold` after the clip's audio would end. Only a clip whose delivery reported `sent` is held, so
/// a user's own words are never dropped as the echo of audio they never heard. In memory only, never logged.
final class HostPhrases: Sendable {
    static let maxPhrases = 8
    private let phrases = Mutex<[(words: [String], expires: ContinuousClock.Instant)]>([])
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) { self.now = now }

    /// Holds `clip`'s words when its delivery `outcome` was `sent`; any other outcome holds nothing.
    func observe(_ clip: AmbientAckClip, outcome: String) {
        guard outcome == "sent", let text = clip.text, clip.sampleRate > 0 else { return }
        let instant = now(), words = RecentSpokenReplies.words(text)
        let audio = Duration.seconds(Double(clip.pcm.count) / Double(2 * clip.sampleRate))
        phrases.withLock { phrases in
            phrases.removeAll { $0.expires <= instant }
            phrases.append((words, instant.advanced(by: audio + RecentSpokenReplies.hold)))
            if phrases.count > Self.maxPhrases { phrases.removeFirst(phrases.count - Self.maxPhrases) }
        }
    }

    /// True when `heard` repeats a held phrase word for word.
    func isEcho(_ heard: String) -> Bool {
        let instant = now(), words = RecentSpokenReplies.words(heard)
        guard !words.isEmpty else { return false }
        return phrases.withLock { $0.contains { $0.expires > instant && $0.words == words } }
    }
}
#endif
/// The final delivery step of an admitted request. The consumer keeps every validation and correlation rule
/// in front of this call and treats any thrown error as terminal; implementations must not retry on their own.
/// `RightyoHostDispatcher` is the direct path; `haild rightyo --reply-to` supplies a reply-socket dispatcher.
public protocol RightyoDispatching: Sendable {
    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt
    /// `routed` (#636): the consumer's own route match chose `target`, a voice route the owner named. The default
    /// delivers an un-routed request as any other and refuses a routed one: only a dispatcher that binds the route
    /// (the listener's ambient step) may carry it, so a route never reaches its target unbound.
    func dispatch(text: String, target: String, binding: String, routed: Bool) async throws -> RightyoDispatchReceipt
}

extension RightyoDispatching {
    public func dispatch(
        text: String, target: String, binding: String, routed: Bool
    ) async throws -> RightyoDispatchReceipt {
        guard !routed else { throw LocalDispatchRefusal.notAuthorized }
        return try await dispatch(text: text, target: target, binding: binding)
    }
}
/// The direct path: `HailHost.send` from the fixed `rightyo-local` device with the pinned binding. A
/// confirmation read-back is cancelled and refused; this consumer never confirms on the person's behalf.
public struct RightyoHostDispatcher: RightyoDispatching {
    public static let device = "rightyo-local"
    private let host: HailHost
    public init(host: HailHost) { self.host = host }
    public func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        let outcome = try await host.send(text, to: target, from: Self.device, expectedBinding: binding)
        if case .needsConfirmation(let readBack) = outcome {
            await host.cancel(readBack.hash)
            throw RightyoInputError.confirmationRequired
        }
        return RightyoDispatchReceipt(request: nil)
    }
}
/// Why a target id cannot be named in the reply block (#188 item 1); refused at startup, before any event. The
/// diagnostic names the rule, never the id, so `haild rightyo` can print it as is.
public enum RightyoTargetError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Outside the allowlist `[A-Za-z0-9][A-Za-z0-9._:-]{0,95}`, the only shape the shell-shaped block quotes safely.
    case unsafeIdentifier
    /// The block built for the id matches the named default guard rules, so every request would need confirmation.
    case guarded([String])
    public var description: String {
        switch self {
        case .unsafeIdentifier:
            "target id must match [A-Za-z0-9][A-Za-z0-9._:-]{0,95} to be named in the reply block"
        case .guarded(let rules): "target name would trigger the content guard (\(rules.joined(separator: ", ")))"
        }
    }
}
/// One explicit producer session and immutable target binding. Failures never imply rollback or permit retry.
public actor RightyoInputConsumer {
    /// nil validates only (dry run): no delivery step exists.
    private let dispatcher: (any RightyoDispatching)?
    /// True for heard text that is the host's own reply coming back through the mic (#269); never dispatched.
    private let echoFilter: (@Sendable (String) -> Bool)?
    /// Requests dropped as own-voice echo. A count only, never their text.
    public private(set) var echoDropped = 0
    private let allowSynthetic: Bool
    private let target: String
    private let binding: String
    private let session: String
    private let streamBudgetMs: Int?
    private var started = false, terminal = false, busy = false, activationEnabled = false, failed = false
    private var sequence = 0, emittedAt = 0
    private var speakers = "anonymous"
    /// The keyed addressing names a voice mute may start with (#404), from the accepted `started`.
    private var voiceNames = Set<String>()
    /// Whether `started` advertised `request_forming` (#188 item 4): then every request must carry `formed_request`,
    /// otherwise none may. Forming is allowed on anonymous sessions too (hosts pick), where any role the formed text
    /// names is uncheckable: only the JSON record behind it carries verified roles, and anonymous sessions have none.
    private var forming = false
    /// Whether `started` advertised `dismissal` version 1 (rightyo#98): only then is `dismiss` admitted.
    /// Likewise `conversation` (rightyo#82): only then are `conversation` events and follow-up requests (recipient
    /// `unknown`) admitted.
    private var dismissible = false, conversational = false
    /// The latest admitted conversation state, `engaged` or `ambient`, and how many changes were admitted.
    public private(set) var conversationStatus = (state: "ambient", changes: 0)
    /// Request ids a `dismiss` withdrew before this consumer delivered them; a later request with one is dropped.
    private var withdrawn = Set<String>()
    /// Withdrawn ids a request has already been dropped for, so a repeat is refused as a duplicate (a subset of `withdrawn`).
    private var dropped = Set<String>()
    /// Requests dropped because a dismissal had withdrawn them. A count only.
    public private(set) var withdrawnDropped = 0
    private var requests = Set<String>()
    private var superseded = Set<String>()
    private var decided = Set<String>()
    /// Utterance ids whose admitted transcript carried `role: owner` and whose admitted attention record, if any,
    /// carried it too (#188 item 3). A subset of `finals`, so the 1,000-finals cap bounds it.
    private var owners = Set<String>()
    private var finals: [String: Data] = [:]
    private var attentions: [String: Data] = [:]
    private var seen: [Int: Data] = [:]
    /// The receipt of the most recent delivered request; nil until one is delivered and cleared as each event
    /// is consumed, so a caller reads only the receipt of the event it just passed in.
    public private(set) var lastReceipt: RightyoDispatchReceipt?
    /// What the most recent admitted `dismiss` did; cleared as each event is consumed, like `lastReceipt`.
    public private(set) var lastDismissal: RightyoDismissReceipt?
    /// The owner's spoken mute or unmute (#404): an admitted request that is exactly a mute phrase, held back from
    /// the target and left here, like a dismissal. Nil for any other line.
    private(set) var lastVoiceMute: VoiceMute.Command?
    /// The owner's spoken media mode (#551), held back like `lastVoiceMute`. Nil for any other line.
    private(set) var lastVoiceMedia: VoiceMedia.Command?
    /// Whether media phrases are commands (#551): only when the child has a control descriptor to carry them.
    private let mediaCommands: Bool
    /// Privacy mode (#735, internally duck): what the latest event asked, held back from the agent like
    /// `lastVoiceMute`; nil for any other line. Only with `duckActive` (a host that handles privacy), which says
    /// whether privacy is on.
    private(set) var lastPrivacy: PrivacyCommand?
    private let duckActive: (@Sendable () -> Bool)?
    /// Utterances whose transcript already carried a safety-set phrase: their request is held back with nothing more.
    private var privacyHeld: [String] = []
    /// `started` advertised `duck` version 2 or higher ("keeps nothing", rightyo S-1): only then is `privacy` admitted.
    private var privacyCapable = false
    /// Utterances whose transcript RightyO attributed to the owner from a live voiceprint (`role_source`): only these
    /// may enter privacy. A subset of `finals`, so its cap bounds this.
    private var voiceprintOwners = Set<String>()
    /// The owner's note to an allowlisted destination (#552), held back like `lastVoiceMute`; nil for any other line.
    private(set) var lastVoiceDestination: VoiceDestinations.Command?
    private let destinations: VoiceDestinations?
    /// The owner's voice routes (#636); nil leaves every request on `target`. A request the owner addressed to a route
    /// that cannot take it is held back, its reason left in `lastRouteRefusal` like a dismissal, and ends nothing.
    private let routing: RightyoVoiceRouting?
    private(set) var lastRouteRefusal: RightyoVoiceRouting.Refusal?
    /// `streamBudgetMs` is an optional ceiling on producer stream time; the default is no ceiling (#188).
    /// `dispatcher` replaces the direct `HailHost.send` step (#188 item 1); without it, `host` delivers directly
    /// and nil `host` validates only. A dispatcher with no host still delivers (it owns its own host access).
    /// `target` is quoted verbatim into every prompt's reply block, so `validateTarget` refuses an unsafe or
    /// guarded id at startup rather than delivering it.
    public init(host: HailHost?, target: String, binding: String, session: String,
                allowSynthetic: Bool = false, streamBudgetMs: Int? = nil,
                dispatcher: (any RightyoDispatching)? = nil, echoFilter: (@Sendable (String) -> Bool)? = nil,
                mediaCommands: Bool = false, destinations: VoiceDestinations? = nil,
                routing: RightyoVoiceRouting? = nil, duckActive: (@Sendable () -> Bool)? = nil) throws {
        guard !binding.isEmpty, RightyoInputEvent.identifier(session), streamBudgetMs.map({ $0 >= 0 }) ?? true else {
            throw RightyoInputError.unavailableBinding
        }
        try Self.validateTarget(target)
        self.dispatcher = dispatcher ?? host.map { RightyoHostDispatcher(host: $0) }
        (self.echoFilter, self.mediaCommands, self.destinations) = (echoFilter, mediaCommands, destinations)
        (self.routing, self.duckActive) = (routing, duckActive)
        self.allowSynthetic = allowSynthetic
        self.target = target
        self.binding = binding
        self.session = session
        self.streamBudgetMs = streamBudgetMs
    }
    /// The reply block is a shell-shaped instruction that names the target verbatim, so the id must match the
    /// allowlist `[A-Za-z0-9][A-Za-z0-9._:-]{0,95}`: every listed `kind:name` shape the adapters produce
    /// (`tmux:demo`, `tmux-reply:main.0`, `tmux:dev.2:0`) and nothing a shell could read as syntax. tmux names may
    /// legally contain spaces or `;`; such a target is unusable for `haild rightyo` until it is renamed. The block
    /// for the id is then matched against the default guard rules, so an authorized name carrying a guarded word
    /// (`tmux:sudo`) is refused here with a diagnostic instead of turning every request into
    /// `confirmationRequired`; a daemon policy with custom guard patterns can still require confirmation, which
    /// the consumer refuses per request as before. The block is fixed host text around the allowlisted id, so it is
    /// matched without the guard's time budget (#658): a stalled scheduler at login or stream start must not refuse a
    /// benign id. Delivered requests keep the budget and its timeout-is-a-hit rule (#208).
    public static func validateTarget(_ target: String) throws {
        let alphanumeric = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        guard let first = target.first, alphanumeric.contains(first), target.count <= 96,
              target.allSatisfy({ alphanumeric.contains($0) || "._:-".contains($0) }) else {
            throw RightyoTargetError.unsafeIdentifier
        }
        let hits = DangerousPatternGuard.targetBlockMatches(target: target)
        guard hits.isEmpty else { throw RightyoTargetError.guarded(hits) }
    }
    /// True means handled: guarded delivery, or validation only when initialized with no host. An admitted `dismiss`
    /// delivers nothing and returns false; `lastDismissal` then says what it did.
    public func consume(_ event: RightyoInputEvent) async throws -> Bool {
        lastReceipt = nil
        lastDismissal = nil
        lastVoiceMute = nil
        (lastVoiceMedia, lastVoiceDestination, lastRouteRefusal, lastPrivacy) = (nil, nil, nil, nil)
        do {
            guard try admit(event) else { return false }
            if event.type == "override" { return true }
            try notePrivacy(event)
            guard event.type == "request", let requestID = event.requestId else { return false }
            guard try claim(requestID, provenance: event.turn?.provenance) else { return false }
            guard let dispatcher else { return true }
            // Matched on the heard turn, not the built prompt, whose envelope would bury the echo (#269).
            if let echoFilter, let heard = event.turn?.text, echoFilter(heard) {
                echoDropped += 1
                return false
            }
            // The owner's "mute" or "unmute" (#404) is carried out by the host, never typed to the agent. On an
            // enrolled session only a turn both its transcript and its attention record call the owner's (`owners`)
            // counts; anyone else's is a request like any other. On an anonymous one any voice counts (see
            // `VoiceMute`): the mute is device-local and reversible.
            if let turn = event.turn, holdsPrivacy(turn) || holdsVoiceCommand(turn) { return false }
            // Busy from addressing on: the route's binding lookup suspends, and no event may enter meanwhile.
            busy = true
            defer { busy = false }
            guard let address = await address(event.turn) else { return false }
            return try await deliver(event, to: address, with: dispatcher)
        } catch {
            terminal = true
            failed = true
            throw error
        }
    }
    /// Refuses a duplicate id or, on a live-only consumer, a non-live request; then claims the id. False means
    /// withdrawn by the speaker's dismissal before it arrived: never delivered, and the session goes on. That drop
    /// comes after both refusals, and a repeat of a dropped id is still a duplicate.
    private func claim(_ requestID: String, provenance: String?) throws -> Bool {
        guard requests.count < 1000, !requests.contains(requestID) else { throw RightyoInputError.invalidEvent }
        guard dispatcher == nil || allowSynthetic || provenance == "live-microphone" else {
            terminal = true
            throw RightyoInputError.invalidEvent
        }
        if withdrawn.contains(requestID) {
            guard dropped.insert(requestID).inserted else { throw RightyoInputError.invalidEvent }
            withdrawnDropped += 1
            return false
        }
        requests.insert(requestID)
        return true
    }
    private func admit(_ event: RightyoInputEvent) throws -> Bool {
        try event.validate(session: session, enrolled: speakers == "enrolled", budgetMs: streamBudgetMs)
        guard !busy else { throw RightyoInputError.invalidLifecycle }
        let fingerprint = try RightyoInputEvent.fingerprint(event)
        if let old = seen[event.sequence] {
            guard old == fingerprint else {
                throw RightyoInputError.invalidEvent
            }
            return false
        }
        guard !terminal else { throw RightyoInputError.invalidLifecycle }
        guard event.sequence > sequence, event.emittedAtMs >= emittedAt else {
            throw RightyoInputError.sequenceGap
        }
        guard seen.count < 4096 else { throw RightyoInputError.capacity }
        if event.type == "session" {
            let caps = try event.phase == "started" ? startCapabilities(event) : nil
            try lifecycle(event.phase)
            // Only an accepted first `started` mutates session state; a rejected repeat changes nothing.
            if let caps {
                activationEnabled = caps.activation == "finalized-turn"
                speakers = caps.speakers
                voiceNames = VoiceMute.names(in: event.addressing)
                forming = event.requestForming != nil
                (dismissible, conversational) = (event.dismissal != nil, event.conversation != nil)
                privacyCapable = RightyoInputEvent.privacyVersion(event.duck).map { $0 >= 2 } ?? false
            }
        } else if !started { throw RightyoInputError.invalidLifecycle }
        try correlate(event)
        sequence = event.sequence
        emittedAt = event.emittedAtMs
        seen[event.sequence] = fingerprint
        return true
    }
    public func finish() throws {
        guard terminal, !busy else { throw RightyoInputError.invalidLifecycle }
        if failed { throw RightyoInputError.producerFailed }
    }
}

extension RightyoInputConsumer {
    /// Leaves a spoken mute (#404) or media mode (#551) in `lastVoiceMute` or `lastVoiceMedia`; true when `turn` was
    /// one. Media mode follows the mute's rule: it only changes what this host's RightyO attends to. Without
    /// `mediaCommands` (no control descriptor to carry it) a media phrase is a request like any other. A note to a
    /// destination (#552) writes the owner's data, so it needs an enrolled session and the owner's turn; it is left
    /// in `lastVoiceDestination`.
    private func holdsVoiceCommand(_ turn: RightyoInputEvent.Turn) -> Bool {
        let owner = owners.contains(turn.utteranceId)
        if speakers == "enrolled", owner, let note = destinations?.command(in: turn.text, names: voiceNames) {
            lastVoiceDestination = note
            return true
        }
        guard speakers != "enrolled" || owner else { return false }
        let heard = turn.text
        if let command = VoiceMute.command(in: heard, names: voiceNames) {
            lastVoiceMute = command
        } else if mediaCommands, let command = VoiceMedia.command(in: heard, names: voiceNames) {
            lastVoiceMedia = command
        }
        return lastVoiceMute != nil || lastVoiceMedia != nil
    }
}
extension RightyoInputConsumer {
    /// A safety-set entry phrase (#735 S-2) in a request; true when the request is held back from the agent, decided
    /// from the request's own heard text. When its transcript already carried the phrase (`notePrivacyPhrase`) nothing
    /// more is done; otherwise (a transcript not from the live microphone, or one evicted from `privacyHeld`) the
    /// request carries it out, by the same owner rule. While privacy is on nothing reaches the agent at all: RightyO v2
    /// sends no request then, and one in flight when it began is dropped.
    private func holdsPrivacy(_ turn: RightyoInputEvent.Turn) -> Bool {
        guard let duckActive else { return false }
        guard let match = PrivacyEntry.match(turn.text, names: voiceNames) else { return duckActive() }
        if !privacyHeld.contains(turn.utteranceId) {
            lastPrivacy = privacyCommand(match, owner: owners.contains(turn.utteranceId)
                                         && voiceprintOwners.contains(turn.utteranceId))
        }
        return true
    }

    /// A safety-set entry phrase in a transcript (#735 S-2), so going private never waits for RightyO to form a
    /// request: carried out at most once per utterance, and its request, if one follows, is held back. Only a
    /// live-microphone turn counts (any turn with `allowSynthetic`, tests), as for requests; the assistant's own words
    /// heard back (`echoFilter`) never count.
    func notePrivacyPhrase(_ turn: RightyoInputEvent.Turn) {
        guard duckActive != nil, allowSynthetic || turn.provenance == "live-microphone",
              echoFilter?(turn.text) != true, let match = PrivacyEntry.match(turn.text, names: voiceNames) else {
            return
        }
        lastPrivacy = privacyCommand(match, owner: voiceprintOwners.contains(turn.utteranceId))
        privacyHeld.append(turn.utteranceId)
        if privacyHeld.count > 32 { privacyHeld.removeFirst(privacyHeld.count - 32) }
    }

    /// Entry is the live enrolled owner's alone (Mick, round 2: "only my registered voice should be able to turn
    /// privacy mode on"), the exit's trust bar: an enrolled session, and a turn RightyO attributed to the owner from a
    /// live voiceprint (`role_source: "voiceprint"`; never an inferred or label-configured owner). Anyone else's
    /// phrase, negated or not, is `refused`: held back, logged, and nothing else. Without that source, fail closed.
    private func privacyCommand(_ match: PrivacyEntry.Match, owner: Bool) -> PrivacyCommand {
        guard speakers == "enrolled", owner else { return .refused }
        return match == .enter ? .enter : .stillRecording
    }

    /// RightyO's content-free `privacy` event (rightyo S-1), refused (ending the stream, fail closed) unless the
    /// session advertised `duck` v2. The exit is trusted as RightyO's own check: it emits one only for the enrolled
    /// owner's voice saying the name and an exit phrase, matched locally while it keeps nothing; the host hears no
    /// words then and cannot re-check. Any speaker may ask the status. Neither ever reaches the agent. A transcript
    /// goes to `notePrivacyPhrase`.
    private func notePrivacy(_ event: RightyoInputEvent) throws {
        if event.type == "transcript", let turn = event.turn { notePrivacyPhrase(turn) }
        guard event.type == "privacy" else { return }
        guard privacyCapable else { throw RightyoInputError.invalidEvent }
        if duckActive != nil { lastPrivacy = event.action == "exit" ? .exit : .status }
    }
}
/// Correlation against admitted records lives here so the actor body stays within the type-length limit.
extension RightyoInputConsumer {
    private func startCapabilities(_ event: RightyoInputEvent) throws -> RightyoInputEvent.Capabilities {
        guard let caps = event.capabilities, ["finalized-turn", "disabled"].contains(caps.activation),
              !caps.partials, ["anonymous", "enrolled"].contains(caps.speakers), caps.context else {
            throw RightyoInputError.invalidEvent
        }
        return caps
    }
    private func lifecycle(_ phase: String?) throws {
        switch phase {
        case "started":
            guard !started else { throw RightyoInputError.invalidLifecycle }
            started = true
        case "stopped", "cancelled", "error":
            guard started else { throw RightyoInputError.invalidLifecycle }
            terminal = true
            failed = phase == "error"
        default: throw RightyoInputError.invalidLifecycle
        }
    }
    private func correlate(_ event: RightyoInputEvent) throws {
        switch event.type {
        case "transcript":
            guard let turn = event.turn, finals.count < 1000, finals[turn.utteranceId] == nil else {
                throw RightyoInputError.invalidEvent
            }
            finals[turn.utteranceId] = try RightyoInputEvent.fingerprint(turn)
            if turn.role == "owner" { owners.insert(turn.utteranceId) }
            if turn.role == "owner", event.roleSource == "voiceprint" { voiceprintOwners.insert(turn.utteranceId) }
        case "attention": try attention(event)
        case "override": try supersede(event)
        case "dismiss": try dismiss(event)
        case "conversation": try conversation(event)
        case "request": try request(event)
        default: break
        }
    }
    private func request(_ event: RightyoInputEvent) throws {
        guard activationEnabled, let turn = event.turn, let decision = event.decision,
              decision.followUp != true || conversational,
              (event.formedRequest != nil) == forming, !superseded.contains(event.requestId ?? ""),
              finals[turn.utteranceId] == (try RightyoInputEvent.fingerprint(turn)),
              attentions[event.requestId ?? ""] == (try RightyoInputEvent.fingerprint(decision)) else {
            throw RightyoInputError.invalidEvent
        }
        for prior in event.context?.turns ?? [] {
            guard finals[prior.utteranceId] == (try RightyoInputEvent.fingerprint(prior)) else {
                throw RightyoInputError.invalidEvent
            }
        }
    }
    private func attention(_ event: RightyoInputEvent) throws {
        guard let utterance = event.utteranceId, finals[utterance] != nil, let decision = event.decision,
              decided.count < 1000, decided.insert(utterance).inserted,
              ["attend", "ignore", "uncertain"].contains(decision.label) else {
            throw RightyoInputError.invalidEvent
        }
        // An attention record that does not repeat `owner` demotes the utterance; it can never promote one.
        if decision.role != "owner" { owners.remove(utterance) }
        // An `attend` with no `request_id` forms no request: RightyO sends one for a turn it dismissed, withdrew,
        // superseded or held as a stop phrase (rightyo#98). Nothing is recorded, so `request` refuses any request
        // citing it; only an `attend` that names a request id is checked and recorded.
        if decision.label == "attend", let requestID = event.requestId {
            guard activationEnabled, RightyoInputEvent.addressedToSystem(decision),
                  decision.followUp != true || conversational,
                  requestID == "\(session):\(utterance)", attentions.count < 1000,
                  attentions[requestID] == nil else {
                throw RightyoInputError.invalidEvent
            }
            attentions[requestID] = try RightyoInputEvent.fingerprint(decision)
        }
    }
    /// An owner `override` (#188 item 3) must cite the owner's own admitted transcript and attention records:
    /// both must have carried `role: owner` (`owners`), so an absent, anonymous or non-owner cited turn is
    /// refused (fail closed). The superseded id is recorded whether or not this consumer ever admitted it (a
    /// producer may supersede a request the host refused), idempotently, under the same cap as `requests`. A
    /// request already sent to the pane stays sent: this records precedence and refuses a later request with that id.
    private func supersede(_ event: RightyoInputEvent) throws {
        guard let requestID = event.supersededRequestId, let utterance = event.byUtteranceId,
              owners.contains(utterance), decided.contains(utterance),
              superseded.contains(requestID) || superseded.count < 1000 else {
            throw RightyoInputError.invalidEvent
        }
        superseded.insert(requestID)
    }
    /// A `conversation` event (rightyo#82) is admitted only on a session that advertised `conversation`, and must cite
    /// admitted records: the speaker's own transcript, and for `engaged` the attention that named its request.
    /// It delivers nothing; the state is kept for status and counted.
    private func conversation(_ event: RightyoInputEvent) throws {
        guard conversational, let state = event.state, conversationStatus.changes < Int.max,
              event.utteranceId.map({ finals[$0] != nil }) ?? true,
              event.requestId.map({ attentions[$0] != nil }) ?? true else {
            throw RightyoInputError.invalidEvent
        }
        conversationStatus = (state, conversationStatus.changes + 1)
    }
    /// A `dismiss` (rightyo#98) is admitted only on a session that advertised `dismissal`, and must cite an admitted
    /// transcript: a stop phrase's comes right after it, before its attention. Each listed id this consumer already
    /// delivered stays delivered (withdrawal is advisory); any other id, including one never seen, which is how
    /// RightyO names a request it withheld, is recorded so a later request with it is dropped, idempotently, under
    /// the same cap as `requests`. Scope and role only withhold or stop host action; they never grant any.
    private func dismiss(_ event: RightyoInputEvent) throws {
        guard dismissible, let utterance = event.utteranceId, finals[utterance] != nil,
              let ids = event.withdrawnRequestIds, let scope = event.scope, let reason = event.reason else {
            throw RightyoInputError.invalidEvent
        }
        let delivered = ids.filter(requests.contains)
        let fresh = Set(ids).subtracting(requests).subtracting(withdrawn)
        guard withdrawn.count + fresh.count <= 1000 else { throw RightyoInputError.capacity }
        withdrawn.formUnion(fresh)
        lastDismissal = RightyoDismissReceipt(reason: reason, scope: scope, withdrawn: ids.count - delivered.count,
                                              alreadyDelivered: delivered.count,
                                              owner: event.role == "owner" && owners.contains(utterance))
    }
}

/// The owner's voice routes for ambient requests (#636), and how to read a route's current binding: listed, alive and
/// at the binding its policy allows, or nil. The routes only name targets; the host still checks each delivery.
public struct RightyoVoiceRouting: Sendable {
    /// Why a request the owner addressed to a route was not sent. Nothing went anywhere; the listener logs the reason
    /// only, and slice 5 tells the owner.
    public enum Refusal: Sendable, Equatable {
        /// The route is offline, or refused the request before it was handed off. Carries the route's name.
        case notDelivered(String)
        /// The route's name alone, with nothing to send.
        case nothingToSay(String)
        /// Opening words that sound like a route's name but are none of its spellings.
        case unclear
    }

    public let routes: VoiceRoutes
    public let binding: @Sendable (String) async -> String?

    public init(routes: VoiceRoutes, binding: @escaping @Sendable (String) async -> String?) {
        self.routes = routes
        self.binding = binding
    }
}

extension RightyoInputConsumer {
    /// Where an admitted request goes, with the binding it is pinned to, and the route when it is not `target`.
    struct Address {
        let target: String
        let binding: String
        let route: VoiceRoutes.Route?
    }

    /// The owner's own turn on an enrolled session may name another route (#636), while `target` is itself a route;
    /// every other turn goes to `target`. Speaker labels decide nothing else here: anyone else's "Deck, …" is a
    /// request to `target` like any other. A route that is offline, another route's name alone and a near miss are
    /// held back in `lastRouteRefusal` (nil), so nothing is sent anywhere and the stream goes on; the stream's own
    /// route named alone is typed to `target`, as before routing and as tap-to-talk delivers it.
    func address(_ turn: RightyoInputEvent.Turn?) async -> Address? {
        let own = Address(target: target, binding: binding, route: nil)
        guard let routing, let turn, speakers == "enrolled", owners.contains(turn.utteranceId),
              routing.routes.route(for: target) != nil else { return own }
        switch routing.routes.match(turn.text, names: voiceNames) {
        case .unaddressed:
            return own
        case .routed(let route, _) where route.target == target:
            return own
        case .routed(let route, _):
            guard let pinned = await routing.binding(route.target) else {
                lastRouteRefusal = .notDelivered(route.name)
                return nil
            }
            return Address(target: route.target, binding: pinned, route: route)
        case .nothingToSay(let route) where route.target == target:
            return own
        case .nothingToSay(let route):
            lastRouteRefusal = .nothingToSay(route.name)
            return nil
        case .unclear:
            lastRouteRefusal = .unclear
            return nil
        }
    }

    /// Types the prompt, its reply block naming `address.target`. A routed request the host refuses before its
    /// handoff (any `LocalDispatchRefusal`: offline, rebound, policy, lockdown, rate) is a route refusal that ends
    /// nothing; any other failure (audit, size, cancellation, listener stop) ends the consumer, as before.
    func deliver(
        _ event: RightyoInputEvent, to address: Address, with dispatcher: any RightyoDispatching
    ) async throws -> Bool {
        do {
            try Task.checkCancellation()
            lastReceipt = try await dispatcher.dispatch(
                text: event.prompt(speakers: speakers, target: address.target), target: address.target,
                binding: address.binding, routed: address.route != nil
            )
            return true
        } catch let refusal as LocalDispatchRefusal where !refusal.handedOff {
            guard let route = address.route else {
                terminal = true
                throw refusal
            }
            lastRouteRefusal = .notDelivered(route.name)
            return false
        } catch {
            terminal = true
            throw error
        }
    }
}

extension RightyoVoiceRouting.Refusal {
    /// What the owner's own device shows (#636, slice 5c), worded as tap-to-talk's refusals; never logged.
    public var message: String {
        switch self {
        case .notDelivered(let name): "voice route: \(name) couldn't take it; nothing was sent"
        case .nothingToSay(let name): "voice route: nothing to send to \(name)"
        case .unclear: "voice route: which session? Nothing was sent"
        }
    }

    /// The audit token: the reason only, never the route's name or the words.
    public var token: String {
        switch self {
        case .notDelivered: "reason=not_delivered"
        case .nothingToSay: "reason=nothing_to_say"
        case .unclear: "reason=unclear"
        }
    }
}
