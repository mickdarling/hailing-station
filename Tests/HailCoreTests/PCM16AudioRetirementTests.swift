import Foundation
import Testing
@testable import HailCore

@Suite("PCM16 audio retirement")
struct PCM16AudioRetirementTests {
    @MainActor
    @Test func stopsThenReleasesResourceOffMain() async {
        let result = await withCheckedContinuation { continuation in
            var player: PCM16AudioPlayer? = makePlayer { continuation.resume(returning: $0) }
            #expect(player != nil)
            player = nil
        }
        #expect(result.stoppedOffMain)
        #expect(result.releasedOffMain)
    }
}

@MainActor
@inline(never)
private func makePlayer(onRelease: @escaping @Sendable (RetirementResult) -> Void) -> PCM16AudioPlayer {
    PCM16AudioPlayer(retiring: RetirementProbe(onRelease: onRelease))
}

private struct RetirementResult: Sendable {
    let stoppedOffMain: Bool
    let releasedOffMain: Bool
}

private final class RetirementProbe: ReplyAudioRenderingResource {
    private var stoppedOffMain = false
    let onRelease: @Sendable (RetirementResult) -> Void

    init(onRelease: @escaping @Sendable (RetirementResult) -> Void) {
        self.onRelease = onRelease
        super.init()
    }
    override func stop() { stoppedOffMain = !Thread.isMainThread }

    deinit {
        onRelease(RetirementResult(stoppedOffMain: stoppedOffMain, releasedOffMain: !Thread.isMainThread))
    }
}
