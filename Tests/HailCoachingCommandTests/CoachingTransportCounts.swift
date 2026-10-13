import HailCore
@testable import haild

/// Count effects at the actual owned-child boundary, not from stored qualification/status snapshots.
@MainActor final class TransportCounts {
    var qualifications = 0, buffers = 0
}

@MainActor final class CountedTransport: ForegroundCoachingTransport {
    let child: CoachingChildTransport, counts: TransportCounts
    init(child: CoachingChildTransport, counts: TransportCounts) { self.child = child; self.counts = counts }
    func send(_ control: ForegroundCoachingControl) -> Bool {
        if case .qualify = control { counts.qualifications += 1 }
        return child.send(control)
    }
    func write(_ buffer: AudioCaptureBuffer) -> Bool { counts.buffers += 1; return child.write(buffer) }
    func close() { child.close() }
    func stop() async { await child.stop() }
}
