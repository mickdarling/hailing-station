#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Instant acknowledgement, input side (rightyo#105, #324): advertised names, clips, and the cue at admission.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientAcknowledgementTests {
    static let addressing: JSONValue = .object([
        "names": .array([.string("Haili"), .string("Friday"), .string("Jarvis"), .string("RightyO")]),
        "variants": .object(["Haili": .array([.string("Hailey"), .string("Haley")]),
                             "Jarvis": .array([.string("Jervis")])])
    ])

    @Test func theEarliestAdvertisedNameOrVariantPicksThePersona() {
        let names = RightyoAddressing(Self.addressing)
        #expect(names.persona(in: "Jarvis, what's on Friday?") == "jarvis")
        #expect(names.persona(in: "hey Jervis, open the file") == "jarvis")
        #expect(names.persona(in: "Hailey, stop.") == "haili")
        #expect(names.persona(in: "Righty O, check that") == "rightyo")
        #expect(names.persona(in: "What time is it?") == nil)
        // Whole words only: a name inside a longer word is not a match.
        #expect(names.persona(in: "Fridays are busy") == nil)
    }

    @Test func malformedOrOversizedAddressingYieldsFewerNamesNeverAFailure() {
        #expect(RightyoAddressing(nil).spellings.isEmpty)
        #expect(RightyoAddressing(.string("Jarvis")).spellings.isEmpty)
        #expect(RightyoAddressing(.object(["names": .array([.integer(3), .string("")])])).spellings.isEmpty)
        let many = JSONValue.object(["names": .array((0..<20).map { .string("Name\($0)") })])
        #expect(RightyoAddressing(many).spellings.count == RightyoAddressing.maxNames)
        let long = JSONValue.object(["names": .array([.string(String(repeating: "a", count: 49))])])
        #expect(RightyoAddressing(long).spellings.isEmpty)
    }

    @Test func onlyMonoPCM16WAVThatFitsOneFrameIsAccepted() throws {
        let clip = try #require(AmbientAckClip.wav(Self.wav(samples: 100), text: "On it."))
        #expect(clip.sampleRate == 24_000)
        #expect(clip.pcm.count == 200)
        #expect(clip.text == "On it.")
        #expect(AmbientAckClip.wav(Self.wav(samples: 100, channels: 2), text: nil) == nil)
        #expect(AmbientAckClip.wav(Self.wav(samples: 100, bits: 8), text: nil) == nil)
        #expect(AmbientAckClip.wav(Self.wav(samples: 100, rate: 4_000), text: nil) == nil)
        #expect(AmbientAckClip.wav(Self.wav(samples: PayloadLimits.maxAudioBytes), text: nil) == nil)
        #expect(AmbientAckClip.wav(Data("not a wave file".utf8), text: nil) == nil)
        #expect(AmbientAckClip.wav(Self.wav(samples: 100).prefix(50), text: nil) == nil)
    }

    @Test func theLibraryLoadsPersonaFoldersSkipsBadFilesAndRotates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hs-ack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let jarvis = root.appendingPathComponent("Jarvis"), empty = root.appendingPathComponent("fry")
        for folder in [jarvis, empty] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Self.wav(samples: 10).write(to: jarvis.appendingPathComponent("a.wav"))
        try "Very good, sir.\n".write(to: jarvis.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try Self.wav(samples: 20).write(to: jarvis.appendingPathComponent("b.wav"))
        try Data("junk".utf8).write(to: jarvis.appendingPathComponent("c.wav"))
        try Data("junk".utf8).write(to: empty.appendingPathComponent("d.wav"))

        let library = AmbientAckLibrary(directory: root)
        #expect(Array(library.clips.keys) == ["jarvis"])
        #expect(library.clips["jarvis"]?.map(\.text) == ["Very good, sir.", nil])
        #expect([0, 1, 2, 3].compactMap { _ in library.next(for: "jarvis")?.index } == [0, 1, 0, 1])
        #expect(library.next(for: "fry") == nil)
        #expect(AmbientAckLibrary(directory: root.appendingPathComponent("missing")).clips.isEmpty)
    }

    /// The fixture's request ("Rightyo, check our discussion.") under a `started` that advertises names.
    static let fixtureWithNames = """
        /usr/bin/sed -e '$d' -e "s/tool-demo/$7/g" \
          -e 's/"phase": "started",/"addressing": {"names": ["Friday", "RightyO"]}, "phase": "started",/' events.jsonl
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        """

    @Test func anAdmittedRequestIsAcknowledgedOnceBeforeItIsTyped() async throws {
        let fake = try FakeRightyo(Self.fixtureWithNames)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let acks = Mutex<[AmbientAckRequest]>([])
        let dispatcher = AckOrderDispatcher(acks: { acks.withLock { $0.count } })
        let pipeline = try RightyoAmbientPipeline(configuration: .init(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            onAcknowledge: { request in acks.withLock { $0.append(request) } }
        ), dispatcher: dispatcher)
        pipeline.finishInput()
        #expect(try await pipeline.run().delivered == 1)
        let seen = acks.withLock { $0 }
        #expect(seen.count == 1)
        #expect(seen.first?.persona == "rightyo")
        #expect(seen.first?.rightyoMs == 100)
        // The acknowledgement came first: the dispatcher saw it already recorded when typing began.
        #expect(await dispatcher.acksAtDispatch == [1])
    }

    @Test func anEchoDroppedRequestIsNeverAcknowledged() async throws {
        let fake = try FakeRightyo(Self.fixtureWithNames)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let acks = Mutex(0)
        let pipeline = try RightyoAmbientPipeline(configuration: .init(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            isEcho: { _ in true }, onAcknowledge: { _ in acks.withLock { $0 += 1 } }
        ), dispatcher: RecordingAmbientDispatcher())
        pipeline.finishInput()
        #expect(try await pipeline.run().delivered == 0)
        #expect(acks.withLock { $0 } == 0)
    }

    static func wav(samples: Int, channels: Int = 1, bits: Int = 16, rate: Int = 24_000) -> Data {
        let size = samples * channels * bits / 8
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        func le16(_ value: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        var bytes = Array("RIFF".utf8) + le32(36 + size) + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(16) + le16(1) + le16(channels) + le32(rate)
        bytes += le32(rate * channels * bits / 8) + le16(channels * bits / 8) + le16(bits)
        bytes += Array("data".utf8) + le32(size) + [UInt8](repeating: 1, count: size)
        return Data(bytes)
    }
}

/// Records how many acknowledgements had fired when each dispatch (the typing) began.
actor AckOrderDispatcher: RightyoAmbientDispatching {
    private(set) var acksAtDispatch: [Int] = []
    private let acks: @Sendable () -> Int

    init(acks: @escaping @Sendable () -> Int) { self.acks = acks }

    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        acksAtDispatch.append(acks())
        return UUID()
    }
}
#endif
