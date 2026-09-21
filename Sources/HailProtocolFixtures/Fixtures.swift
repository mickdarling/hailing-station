public import Foundation
public import HailProtocol

/// The canonical example frames. Both ends' test targets decode and re-encode every one of these and
/// compare bytes to `fixtures/frames/<name>.json`; a change here without regenerating fails CI (#2, #28).
/// The JSON copies ship in this module's resource bundle so tests find them from any host or app bundle.
public enum Fixtures {
    /// The checked-in JSON for one example, from the resource bundle.
    public static func data(for name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "frames") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "frames/\(name).json"])
        }
        return try Data(contentsOf: url)
    }

    /// Every control command that has a fixture, by wire name, so a command without one fails a test.
    public static var controlCommandsCovered: Set<String> {
        Set(all.compactMap { example -> String? in
            guard case .control(let control) = example.frame.payload else { return nil }
            return String(describing: control).split(separator: "(").first.map(String.init)
        })
    }

    /// The negative fixtures under `fixtures/invalid`: each must fail `FrameCoding.decode` and, unless marked
    /// `_expect: schema-pass`, fail schema validation too (#62 review).
    public static func invalidNames() -> [String] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "invalid") ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    public static func invalidData(for name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "invalid") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "invalid/\(name).json"])
        }
        return try Data(contentsOf: url)
    }

    /// Names of every JSON file in the bundle, so a stale file with no in-code example is caught.
    public static func namesOnDisk() -> Set<String> {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "frames") ?? []
        return Set(urls.map { $0.deletingPathExtension().lastPathComponent })
    }

    public struct Example: Sendable {
        public let name: String
        public let frame: Frame
    }

    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "0B0B0B0B-0000-4000-8000-%012ld", number)) ?? UUID()
    }

    private static let audioBytes = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00])

    public static let all: [Example] = [
        Example(name: "text-final", frame: Frame(
            id: id(1), timestamp: 1_758_200_000_000, target: "tmux:claude-hail", source: "terminal",
            payload: .text(TextPayload(text: "run the tests and tell me what failed", isFinal: true))
        )),
        Example(name: "text-partial", frame: Frame(
            id: id(2), timestamp: 1_758_200_000_100, target: "tmux:claude-hail", source: "terminal",
            payload: .text(TextPayload(text: "run the", isFinal: false))
        )),
        Example(name: "audio-opus-segment", frame: Frame(
            id: id(3), timestamp: 1_758_200_004_000, target: "tmux:claude-hail", source: "tmux:claude-hail",
            payload: .audio(AudioPayload(
                codec: .opus, sampleRate: 48_000, channels: 1, sequence: 0, bytes: audioBytes
            ))
        )),
        Example(name: "image-reserved", frame: Frame(
            id: id(4), timestamp: 1_758_200_005_000, target: "tmux:claude-hail", source: "tmux:claude-hail",
            payload: .image(ImagePayload(
                mimeType: "image/png", width: 2, height: 2, bytes: Data([0x89, 0x50, 0x4E, 0x47])
            ))
        )),
        Example(name: "frame-reserved", frame: Frame(
            id: id(5), timestamp: 1_758_200_006_000, target: "tmux:claude-hail", source: "tmux:claude-hail",
            payload: .frame(ScreenFramePayload(
                mimeType: "image/jpeg", width: 1, height: 1, streamID: "win-claude", index: 12,
                bytes: Data([0xFF, 0xD8])
            ))
        )),
        Example(name: "control-hello", frame: Frame(
            id: id(6), timestamp: 1_758_200_000_000, source: "terminal",
            payload: .control(.hello(HelloInfo(
                versions: [1], capabilities: ["audio.opus", "text"], deviceName: "iPad Pro"
            )))
        )),
        Example(name: "control-targets", frame: Frame(
            id: id(7), timestamp: 1_758_200_000_050, source: "host",
            payload: .control(.targets([
                TargetInfo(id: "tmux:claude-hail", kind: "tmux", name: "Claude: hail", alive: true),
                TargetInfo(id: "tmux:codex-hail", kind: "tmux", name: "codex-hail", alive: false)
            ]))
        )),
        Example(name: "control-select", frame: Frame(
            id: id(8), timestamp: 1_758_200_000_060, source: "terminal",
            payload: .control(.select(targetID: "tmux:claude-hail"))
        )),
        Example(name: "control-list-targets", frame: Frame(
            id: id(12), timestamp: 1_758_200_000_040, source: "terminal", payload: .control(.listTargets)
        )),
        Example(name: "control-subscribe", frame: Frame(
            id: id(13), timestamp: 1_758_200_000_061, source: "terminal",
            payload: .control(.subscribe(targetID: "tmux:codex-hail"))
        )),
        Example(name: "control-unsubscribe", frame: Frame(
            id: id(14), timestamp: 1_758_200_000_062, source: "terminal",
            payload: .control(.unsubscribe(targetID: "tmux:codex-hail"))
        )),
        Example(name: "control-escape", frame: Frame(
            id: id(18), timestamp: 1_758_200_000_063, source: "terminal",
            payload: .control(.escape(targetID: "tmux:codex-hail"))
        )),
        Example(name: "control-ping", frame: Frame(
            id: id(9), timestamp: 1_758_200_015_000, source: "terminal", payload: .control(.ping(nonce: "n-0001"))
        )),
        Example(name: "control-pong", frame: Frame(
            id: id(15), timestamp: 1_758_200_015_020, source: "host", payload: .control(.pong(nonce: "n-0001"))
        )),
        Example(name: "text-unicode-and-slashes", frame: Frame(
            id: id(16), timestamp: 1_758_200_030_000, target: "tmux:claude-hail", source: "terminal",
            payload: .text(TextPayload(text: "open ~/Projects/example/docs and say \"héllo\" 🙂 \t tab", isFinal: true))
        )),
        Example(name: "unknown-with-double", frame: Frame(
            id: id(17), timestamp: 1_758_200_031_000, source: "host",
            payload: .unknown(type: "telemetry", payload: .object(["ratio": .number(0.125), "neg": .integer(-7)]))
        )),
        Example(name: "control-error", frame: Frame(
            id: id(10), timestamp: 1_758_200_000_070, source: "host",
            payload: .control(.error(code: .notAllowed, message: "target tmux:codex-hail is not allowed yet"))
        )),
        Example(name: "unknown-type", frame: Frame(
            id: id(11), timestamp: 1_758_200_020_000, target: "tmux:claude-hail", source: "tmux:claude-hail",
            payload: .unknown(type: "hologram", payload: .object(["shape": .string("cube"), "faces": .integer(6)]))
        ))
    ]
}
