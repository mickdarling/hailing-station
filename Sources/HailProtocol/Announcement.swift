/// Short announcements the app speaks itself (#825 S4b; #735 S-7c adds its keys). What is spoken is each key's
/// `fallbackText`: a bundled clip must say exactly these words (#820), or else the device's system voice says them.
/// Both sides link this, so haild's echo filter can learn every announcement's words.
public enum Announcement: String, CaseIterable, Sendable {
    /// A reply's stream ended without its final audio.
    case replyAudioLost = "reply_audio_lost"
    /// A reply's audio failed to play.
    case replyAudioFailed = "reply_audio_failed"

    public var fallbackText: String {
        switch self {
        case .replyAudioLost: "The reply's audio didn't arrive in full."
        case .replyAudioFailed: "The reply's audio couldn't play."
        }
    }
}
