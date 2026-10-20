public import Foundation
import HailProtocol

/// Text the user pasted into the conversation (#608), checked on the device before it goes anywhere. It rides with the
/// next spoken request or is sent on its own, and the host frames it as untrusted data. Shared so a Mac client can use
/// the same rules and the same collapsed preview.
public struct PastedDraft: Equatable, Sendable {
    public enum Problem: Error, Equatable, Sendable {
        case empty
        /// Over the paste cap, in the paste's own bytes.
        case tooLarge(bytes: Int, limit: Int)
        /// Within the cap, but so many characters need escaping that the request no longer fits one frame.
        case tooManySpecialCharacters
        /// The connected Mac does not advertise `pasted_text`, so it would drop the paste silently.
        case unsupportedByHost
        /// The Mac refused this paste request, with its reason (#608): the connection stays up.
        case refusedByHost(String)

        /// The sentence the station shows. Wording is a placeholder for Mick to approve (#608).
        public var message: String {
            switch self {
            case .empty: "There's no text to paste."
            case .tooLarge(let bytes, let limit):
                "The pasted text is too large (\(Self.kilobytes(bytes)) KB; the limit is \(Self.kilobytes(limit)) KB)."
            case .tooManySpecialCharacters:
                "The pasted text has too many special characters to send at once. Try a shorter paste."
            case .unsupportedByHost: "This Mac's Hailing Station is too old to take pasted text. Update haild."
            case .refusedByHost(let reason): "The Mac didn't take the paste: \(reason)."
            }
        }

        private static func kilobytes(_ bytes: Int) -> Int { (bytes + 1023) / 1024 }
    }

    /// A paste longer than this many lines, or than `collapsedCharacters`, starts collapsed in the transcript.
    public static let collapsedLines = 4
    public static let collapsedCharacters = 280

    public let text: String

    public init(_ text: String) throws(Problem) {
        guard text.contains(where: { !$0.isWhitespace }) else { throw .empty }
        let bytes = text.utf8.count
        guard bytes <= PayloadLimits.maxPastedTextBytes else {
            throw .tooLarge(bytes: bytes, limit: PayloadLimits.maxPastedTextBytes)
        }
        self.text = text
    }

    public var lineCount: Int { Self.lineCount(text) }

    /// Whether the transcript shows this paste collapsed at first.
    public var isLong: Bool { Self.isLong(text) }

    /// The collapsed form: the first `collapsedLines` lines, cut at `collapsedCharacters`, with an ellipsis when cut.
    public var preview: String { Self.preview(text) }

    public static func lineCount(_ text: String) -> Int {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    public static func isLong(_ text: String) -> Bool {
        lineCount(text) > collapsedLines || text.count > collapsedCharacters
    }

    public static func preview(_ text: String) -> String {
        guard isLong(text) else { return text }
        let head = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .prefix(collapsedLines).joined(separator: "\n")
        return String(head.prefix(collapsedCharacters)) + "…"
    }
}

extension PastedDraft {
    /// The encoded final text frame. One carrying a paste goes only to a host that advertises `pasted_text`, since an
    /// older host would drop it silently, and only when it fits the host's frame cap; otherwise nothing is sent.
    static func encodedRequest(_ frame: Frame, hostCapabilities: [String]) throws -> Data {
        guard case .text(let text) = frame.payload, text.pasted != nil else { return try FrameCoding.encode(frame) }
        guard hostCapabilities.contains(PastedText.capability) else { throw Problem.unsupportedByHost }
        let data = try FrameCoding.encode(frame)
        guard data.count <= PayloadLimits.defaultMaxFrameBytes else { throw Problem.tooManySpecialCharacters }
        return data
    }
}

extension PastedDraft {
    /// Target kinds a Mac may deliver a paste to (#608): the Codex app-server adapter, and tmux, whose pane the Mac
    /// checks runs an agent. A refusal from either keeps the connection.
    public static let pasteTargetKinds: Set<String> = ["codex-owned", "tmux"]
}

/// A paste request a Mac refused (#608), and the pasted turn it belongs to.
public struct PasteRefusal: Equatable, Sendable {
    public let id = UUID()
    public let endpointID: HostEndpoint.Identifier
    public let entryID: String
    public let pasted: String
    public let message: String
}

extension HostConnection {
    /// The final text with a paste (#608): `pasted` goes only to a host that advertises `pasted_text` and only in a
    /// frame within the host's cap; otherwise nothing is sent and the problem says why.
    public func sendFinalText(_ text: String, pasted: PastedDraft, to targetID: String) async throws {
        try requireReady(capability: "send_text")
        let payload = TextPayload(text: text, pasted: PastedText(text: pasted.text))
        let data = try PastedDraft.encodedRequest(Frame(
            version: snapshot.negotiatedVersion ?? ProtocolVersion.current, timestamp: wallNow(), target: targetID,
            source: deviceName, payload: .text(payload)
        ), hostCapabilities: snapshot.capabilities)
        guard let socket else { throw HostConnectionFailure.notReady }
        try await socket.send(data)
    }
}
