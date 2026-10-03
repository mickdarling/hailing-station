import Foundation
import HailCore
import HailProtocol
import Testing

@Suite struct HostConnectionAudioSequenceTests {
    @Test func refusesRepeatedOrDecreasingSequencesLocally() async throws {
        let (connection, socket) = try await readyAudioConnection(capabilities: ["select_target", "stream_audio"])
        let stream = UUID()
        try await connection.sendAudio(ambientSegment(stream: stream))
        try await connection.sendAudio(ambientSegment(stream: stream, sequence: 3))
        for sequence in [3, 2, 0] {
            await #expect(throws: HostConnectionFailure.malformed("ambient sequence must increase")) {
                try await connection.sendAudio(ambientSegment(stream: stream, sequence: sequence))
            }
        }
        try await connection.sendAudio(ambientSegment(stream: stream, sequence: 4))
        #expect(try await audioFrames(socket).compactMap {
            if case .audio(let audio) = $0.payload { return audio.sequence }
            return nil
        } == [0, 3, 4])
        await connection.disconnect()
    }
}
