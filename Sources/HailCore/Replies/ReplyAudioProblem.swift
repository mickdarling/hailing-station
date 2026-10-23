/// A reply whose audio did not play is never silent (#825, #822): its entry says so, and the app announces it once.
extension ReplyPlaybackController {
    public nonisolated static let audioDidNotArrive = "Audio didn't arrive"
    public nonisolated static let audioCouldNotPlay = "Audio couldn't play"

    /// Why `replyID`'s audio did not play, or nil: it ended without its final audio (#469), or playback failed.
    public func audioProblem(replyID: String) -> String? {
        presentationStatuses[replyID].flatMap(Self.audioProblem)
    }

    /// Every reply whose audio did not play, by presentation id. Observable, since it reads the recorded statuses.
    public var audioProblems: [String: String] {
        presentationStatuses.compactMapValues(Self.audioProblem)
    }

    nonisolated static func audioProblem(_ status: String) -> String? {
        if status == abandonedStatus { return audioDidNotArrive }
        return DeviceDiagnostics.playbackFailure(status) == nil ? nil : audioCouldNotPlay
    }
}
