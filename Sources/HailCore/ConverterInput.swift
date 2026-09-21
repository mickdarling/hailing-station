import AVFAudio

final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
