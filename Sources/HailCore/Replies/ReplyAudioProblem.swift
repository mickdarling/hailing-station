/// A reply whose audio did not play says so on its entry (#825, #822). Only real losses count: a stream that ended
/// without its final audio (#469), or audio that failed to play. A refused duplicate segment is not one (the first copy
/// plays), nor a replay or a resume that failed after the reply was heard.
extension ReplyPlaybackController {
    public nonisolated static let audioDidNotArrive = "Audio didn't arrive in full"
    public nonisolated static let audioCouldNotPlay = "Audio couldn't play"
    /// The status of a stream that ended without its final audio (#469), for the app's deferred announcements.
    public nonisolated static var endedWithoutFinalAudio: String { abandonedStatus }

    /// Why `replyID`'s audio did not play, or nil.
    public func audioProblem(replyID: String) -> String? {
        presentationStatuses[replyID].flatMap(Self.audioProblem)
    }

    nonisolated static func audioProblem(_ status: String) -> String? {
        switch status {
        case abandonedStatus: audioDidNotArrive
        case "Playback failed", "Audio format is not yet playable": audioCouldNotPlay
        default: nil
        }
    }
}
