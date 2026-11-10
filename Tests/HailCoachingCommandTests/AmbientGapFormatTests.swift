#if os(macOS)
import HailCore
import Testing
@testable import HailDaemonKit

@Suite struct AmbientGapFormatTests {
    @Test func hostGapDurationMatchesCanonicalTerminalChunks() {
        #expect(AmbientGapFill.chunkBytes == AmbientAudioFormat.chunkBytes)
        #expect(AmbientGapFill.maxBytes == 96_000)
        #expect(AmbientGapFill.maxBytes.isMultiple(of: MemoryLayout<Int16>.size))
    }
}
#endif
