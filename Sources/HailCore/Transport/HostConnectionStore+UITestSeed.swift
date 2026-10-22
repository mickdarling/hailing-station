#if DEBUG
/// DEBUG builds only (#717): the station's `-seed-conversation` UI test argument feeds invented host frames through
/// the same path a connected host's frames take, so the chat fills exactly as it does in a long ambient session.
extension HostConnectionStore {
    public func ingestForUITesting(_ event: HostReplyEvent) {
        if receiveAmbientNotice(event) { return }
        conversation.noteReply(event)
    }
}
#endif
