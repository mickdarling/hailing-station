#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Fixed fixture tokens only: never retain endpoints, identities, transcript/PCM or unknown wire strings.
final class AmbientVoiceMuteDiagnostic: Sendable {
    private let stages = Mutex<[String]>([])
    var summary: String { stages.withLock { $0.joined(separator: ",") } }

    func record(_ event: WebSocketListenerEvent) {
        let token: String
        switch event.event {
        case "ambient_started": token = "ambient_started"
        case "ambient_refused", "ambient_ended": token = "\(event.event):\(Self.reason(event.detail ?? ""))"
        default: return
        }
        stages.withLock { $0.append(token) }
    }

    static func frame(_ payload: FramePayload) -> String {
        switch payload {
        case .control(let control): controlToken(control)
        case .text: "text"
        case .audio: "audio"
        case .image: "image"
        case .frame: "frame"
        case .unknown: "unknown"
        }
    }

    private static func controlToken(_ control: ControlPayload) -> String {
        switch control {
        case .stopPlayback: "control_stop_playback"
        case .pong: "control_pong"
        case .setReplyMute: "control_reply_mute"
        case .error(let code, let message): "control_error/\(codeToken(code))/\(messageReason(message))"
        default: "control_other"
        }
    }

    private static func codeToken(_ code: ErrorCode) -> String {
        if case .unknown = code { return "unknown" }
        return code.rawValue // Only the protocol's fixed known code spellings remain.
    }

    private static func messageReason(_ message: String) -> String {
        let prefixes = [("ambient unavailable: ", "unavailable"), ("ambient stopped: ", "stopped")]
        for (prefix, token) in prefixes where message.hasPrefix(prefix) {
            return "\(token):\(reason(String(message.dropFirst(prefix.count))))"
        }
        return "other"
    }

    private static func reason(_ detail: String) -> String {
        let replaced = detail.hasPrefix("replaced ")
        let value = replaced ? String(detail.dropFirst(9)) : detail
        let token: String
        if value.hasPrefix("delivered=") { token = "completed" } else {
            guard reasons.contains(value) else { return "other" }
            token = value.replacingOccurrences(of: " ", with: "_")
        }
        return (replaced ? "replaced_" : "") + token
    }

    // Exact vocabulary from the router's content-free describe/refuse paths; additions remain unknown.
    private static let reasons: Set<String> = [
        "busy", "stopping", "failed", "listener input closed", "listener exited",
        "child unsafeExecutable", "child unsafeConfig", "child lineTooLong", "child backlog", "child transportLost",
        "input invalidEvent", "input invalidLifecycle", "input sequenceGap", "input capacity",
        "input unavailableBinding", "input confirmationRequired", "input producerFailed",
        "dispatch unsupported", "dispatch unknownConnection", "dispatch connectionEnded", "dispatch sessionNotReady",
        "dispatch notAuthorized", "dispatch targetNotSelected", "dispatch selectionChanged", "dispatch bindingMismatch",
        "dispatch confirmationRequired", "dispatch capacityExceeded", "dispatch deliveryRefused",
        "dispatch ownershipLost", "dispatch connectionLost", "dispatch sourceHostMismatch",
        "dispatch listenerNotReady",
        "dispatch invalidReplyPayload", "dispatch replyTargetMissing", "dispatch auditFailure",
        "dispatch decodeFailure",
        "dispatch noRecipient", "dispatch requestPending", "dispatch notUniqueRecipient", "dispatch publicationFailed",
        "dispatch replyStopped"
    ]
}

@Suite struct AmbientVoiceMuteDiagnosticTests {
    @Test func unknownContentAndIdentityFieldsNeverEnterTheDiagnostic() {
        let diagnostic = AmbientVoiceMuteDiagnostic()
        let content = "not-a-diagnostic-token"
        diagnostic.record(WebSocketListenerEvent(event: "ambient_refused", sessionID: UUID(),
                                                 endpoint: content, detail: content))
        diagnostic.record(WebSocketListenerEvent(event: content, sessionID: UUID(), endpoint: content, detail: content))
        #expect(diagnostic.summary == "ambient_refused:other")
        let error = AmbientVoiceMuteDiagnostic.frame(.control(.error(code: .unknown(content), message: content)))
        #expect(error == "control_error/unknown/other")
        let text = AmbientVoiceMuteDiagnostic.frame(.text(TextPayload(text: content)))
        #expect(text == "text")
        let opaque = AmbientVoiceMuteDiagnostic.frame(.unknown(type: content, payload: .string(content)))
        #expect(opaque == "unknown")
    }

    @Test func knownStageAndFailureReasonsRetainOnlyAllowedTokens() {
        let diagnostic = AmbientVoiceMuteDiagnostic()
        diagnostic.record(WebSocketListenerEvent(event: "ambient_started", detail: "not-a-diagnostic-token"))
        diagnostic.record(WebSocketListenerEvent(event: "ambient_ended", detail: "input invalidEvent"))
        #expect(diagnostic.summary == "ambient_started,ambient_ended:input_invalidEvent")
        let token = AmbientVoiceMuteDiagnostic.frame(.control(.error(
            code: .notAllowed, message: "ambient unavailable: failed")))
        #expect(token == "control_error/not_allowed/unavailable:failed")
    }
}
#endif
