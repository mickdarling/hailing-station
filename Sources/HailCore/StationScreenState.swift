extension TalkCapturePhase {
    public init(starting: Bool, recording: Bool, finishing: Bool) {
        if finishing {
            self = .finishing
        } else if recording {
            self = .recording
        } else {
            self = starting ? .starting : .idle
        }
    }
}
