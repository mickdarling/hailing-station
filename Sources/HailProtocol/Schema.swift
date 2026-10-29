// The generated schema mirrors every payload in one auditable value.
// swiftlint:disable type_body_length file_length
/// JSON Schema (draft 2020-12) for the frame envelope and payloads, emitted by `hail-protocol-gen` so
/// non-Swift implementers (#15) and the CI drift check (#28) have a machine-readable reference. Maintained
/// beside the Codable types; the conformance job fails when a fixture stops validating.
///
/// Decision (#62 review): unknown keys are permitted at every level, matching the Swift decoders, which ignore
/// them. That keeps an older end tolerant of a newer sender. Limits and required keys are enforced on both sides.
public enum Schema {
    public static let json: JSONValue = .object([
        "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
        "$id": .string("https://hail.invalid/schema/frame-v\(ProtocolVersion.current).json"),
        "title": .string("hail frame"),
        "type": .string("object"),
        "required": .array(["v", "id", "ts", "type", "source", "payload"].map(JSONValue.string)),
        "properties": .object([
            "v": .object(["type": .string("integer"), "minimum": .integer(1)]),
            "id": .object(["type": .string("string"), "format": .string("uuid")]),
            "ts": .object(["type": .string("integer"), "minimum": .integer(0)]),
            "type": .object(["type": .string("string")]),
            "target": .object(["type": .string("string"), "minLength": .integer(1)]),
            "source": .object(["type": .string("string"), "minLength": .integer(1)]),
            "payload": .object(["type": .string("object")])
        ]),
        "allOf": .array(FrameType.allCases.map(payloadRule)),
        "$defs": .object([
            "text": text, "audio": audio, "reply": reply, "image": image, "frame": screenFrame,
            "control": control
        ])
    ])

    private static func payloadRule(_ type: FrameType) -> JSONValue {
        .object([
            "if": .object(["properties": .object(["type": .object(["const": .string(type.rawValue)])])]),
            "then": .object([
                "properties": .object(["payload": .object(["$ref": .string("#/$defs/\(type.rawValue)")])])
            ])
        ])
    }

    private static func base64Length(_ bytes: Int) -> Int64 {
        Int64((bytes + 2) / 3 * 4)
    }

    private static func bytesField(max: Int) -> JSONValue {
        .object([
            "type": .string("string"), "contentEncoding": .string("base64"), "maxLength": .integer(base64Length(max))
        ])
    }

    private static func requiring(_ keys: [String], _ properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("object"), "required": .array(keys.map(JSONValue.string)),
            "properties": .object(properties)
        ])
    }

    private static func commandRule(_ command: String, requires keys: [String]) -> JSONValue {
        .object([
            "if": .object(["properties": .object(["command": .object(["const": .string(command)])])]),
            "then": .object(["required": .array((["command"] + keys).map(JSONValue.string))])
        ])
    }

    private static func integer(_ range: ClosedRange<Int>) -> JSONValue {
        .object([
            "type": .string("integer"),
            "minimum": .integer(Int64(range.lowerBound)), "maximum": .integer(Int64(range.upperBound))
        ])
    }

    private static let text: JSONValue = .object([
        "type": .string("object"), "required": .array([.string("text"), .string("final")]),
        "properties": .object([
            "text": .object(["type": .string("string"), "maxLength": .integer(Int64(PayloadLimits.maxTextBytes))]),
            "final": .object(["type": .string("boolean")]),
            "reply": .object(["$ref": .string("#/$defs/reply")]),
            // #606: a reply's unspoken Markdown; only beside `reply`, never empty.
            "metadata": .object([
                "type": .string("string"), "minLength": .integer(1),
                "maxLength": .integer(Int64(PayloadLimits.maxMetadataBytes))
            ]),
            "pasted": requiring(["text"], [
                "text": .object([
                    "type": .string("string"), "minLength": .integer(1),
                    "maxLength": .integer(Int64(PayloadLimits.maxPastedTextBytes))
                ])
            ])
        ]),
        "allOf": .array([
            .object([
                "if": .object(["required": .array([.string("metadata")])]),
                "then": .object(["required": .array([.string("reply")])])
            ]),
            // #608: a paste rides only on a final frame.
            .object([
                "if": .object(["required": .array([.string("pasted")])]),
                "then": .object(["properties": .object(["final": .object(["const": .bool(true)])])])
            ])
        ])
    ])

    private static let replyBase: JSONValue = requiring(
        ["id", "host", "target", "priority", "interruption"],
        [
            "id": .object(["type": .string("string"), "format": .string("uuid")]),
            "host": .object([
                "type": .string("string"), "minLength": .integer(1),
                "maxLength": .integer(Int64(ReplyLimits.maxIdentifierBytes))
            ]),
            "target": .object([
                "type": .string("string"), "minLength": .integer(1),
                "maxLength": .integer(Int64(ReplyLimits.maxIdentifierBytes))
            ]),
            "audioStream": .object(["type": .string("string"), "format": .string("uuid")]),
            "request": .object(["type": .string("string"), "format": .string("uuid")]),
            "update": .object(["type": .string("string"), "format": .string("uuid")]),
            "priority": .object(["enum": .array(ReplyPriority.allCases.map { .string($0.rawValue) })]),
            "interruption": .object(["enum": .array(ReplyInterruption.allCases.map { .string($0.rawValue) })])
        ]
    )

    private static let reply: JSONValue = {
        guard case .object(var schema) = replyBase else { preconditionFailure("reply schema must be an object") }
        schema["allOf"] = .array([.object([
            "if": .object(["required": .array([.string("update")])]),
            "then": .object([
                "not": .object(["required": .array([.string("request")])]),
                "properties": .object([
                    "priority": .object(["const": .string("background")]),
                    "interruption": .object(["const": .string("enqueue")])
                ])
            ])
        ])])
        // Equality between update and id is additionally enforced by the typed decoder.
        return .object(schema)
    }()

    private static let audio: JSONValue = .object([
        "type": .string("object"),
        "required": .array(["codec", "sampleRate", "channels", "sequence", "bytes"].map(JSONValue.string)),
        "properties": .object([
            "codec": .object(["enum": .array([.string("opus"), .string("pcm16")])]),
            "sampleRate": integer(PayloadLimits.sampleRates),
            "channels": integer(PayloadLimits.channels),
            "sequence": .object(["type": .string("integer"), "minimum": .integer(0)]),
            "streamId": .object(["type": .string("string"), "format": .string("uuid")]),
            "final": .object(["type": .string("boolean")]),
            "bytes": bytesField(max: PayloadLimits.maxAudioBytes),
            "reply": .object(["$ref": .string("#/$defs/reply")]),
            "resume": .object(["const": .bool(true)]), // #373: only on a first segment (below)
            "segmentEnd": .object(["type": .string("boolean"), "const": .bool(true)])
        ]),
        "allOf": .array([
            .object([
                "if": .object(["required": .array([.string("reply")])]),
                "then": .object(["required": .array([.string("streamId"), .string("final")])])
            ]),
            .object(["if": .object(["required": .array([.string("segmentEnd")])]), "then": .object([
                "required": .array(["reply", "streamId", "final"].map(JSONValue.string)),
                "properties": .object([
                    "final": .object(["const": .bool(false)]),
                    "reply": .object(["required": .array([.string("audioStream")])]),
                    // Conflicts with the global true-only rule, forbidding any resume key here.
                    "resume": .object(["const": .bool(false)])
                ])
            ])]),
            .object(["if": .object(["required": .array([.string("resume")])]), "then": .object([
                "required": .array([.string("streamId")]),
                "properties": .object(["sequence": .object(["const": .integer(0)])])
            ])])
        ])
    ])

    private static let image: JSONValue = .object([
        "type": .string("object"),
        "required": .array(["mimeType", "width", "height", "bytes"].map(JSONValue.string)),
        "properties": .object([
            "mimeType": .object(["type": .string("string"), "minLength": .integer(1)]),
            "width": integer(PayloadLimits.dimensions),
            "height": integer(PayloadLimits.dimensions),
            "bytes": bytesField(max: PayloadLimits.maxImageBytes)
        ])
    ])

    private static let screenFrame: JSONValue = .object([
        "type": .string("object"),
        "required": .array(["mimeType", "width", "height", "streamId", "index", "bytes"].map(JSONValue.string)),
        "properties": .object([
            "mimeType": .object(["type": .string("string"), "minLength": .integer(1)]),
            "width": integer(PayloadLimits.dimensions),
            "height": integer(PayloadLimits.dimensions),
            "streamId": .object(["type": .string("string"), "minLength": .integer(1)]),
            "index": .object(["type": .string("integer"), "minimum": .integer(0)]),
            "bytes": bytesField(max: PayloadLimits.maxImageBytes)
        ])
    ])

    /// Only the two heard-turn payloads may carry `turn`; an absent field preserves legacy error extensions.
    private static let heardTurnPayloadRule: JSONValue = .object([
        "if": .object(["required": .array([.string("turn")])]),
        "then": .object([
            "properties": .object([
                "command": .object(["enum": .array([.string("ambient_heard"), .string("error")])]),
                "turn": .object([
                    "type": .string("string"), "format": .string("uuid"),
                    "pattern": .string("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
                ])
            ]),
            "allOf": .array([.object([
                "if": .object(["properties": .object(["command": .object(["const": .string("error")])])]),
                "then": .object([
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "command": .object([:]), "code": .object(["const": .string("voice_route_refused")]),
                        "message": .object([:]), "turn": .object([:])
                    ])
                ])
            ])])
        ])
    ])

    private static let replyYieldPayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("reply_yield")])])]),
        "then": .object([
            "required": .array(["reply", "segment"].map(JSONValue.string)),
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([:]),
                "reply": .object([
                    "type": .string("string"), "format": .string("uuid"), "maxLength": .integer(36),
                    "pattern": .string("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
                ]),
                "segment": integer(1...ReplySegments.maxSegmentEnds)
            ])
        ])
    ])

    private static let control: JSONValue = .object([
        "type": .string("object"), "required": .array([.string("command")]),
        "properties": .object([
            "command": .object(["enum": .array(
                [
                    "hello", "list_targets", "targets", "select", "subscribe", "unsubscribe", "escape", "ping", "pong",
                    "error", "diagnostic", "stop_playback", "ambient_moved_here", "ambient_heard",
                    "ambient_overheard", "overheard_scope", "set_reply_mute", "owner_voice", "ambient_input",
                    "session_update", "session_update_cancel", "health", "health_report", "media_mode",
                    "duck_mode", "set_privacy", "reply_yield"
                ]
                    .map(JSONValue.string)
            )]),
            "hello": requiring(["versions", "capabilities", "deviceName"], [
                "versions": .object([
                    "type": .string("array"), "minItems": .integer(1),
                    "items": .object(["type": .string("integer"), "minimum": .integer(1)])
                ]),
                "capabilities": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "deviceName": .object(["type": .string("string")]),
                "deviceKind": .object(["enum": .array(AmbientTakeOver.deviceKinds.map(JSONValue.string))]),
                "hostInstance": .object([
                    "type": .string("string"), "format": .string("uuid"),
                    "pattern": .string("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
                ])
            ]),
            "targets": .object([
                "type": .string("array"),
                "items": requiring(["id", "kind", "name", "alive"], [
                    "id": .object(["type": .string("string"), "minLength": .integer(1)]),
                    "kind": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "alive": .object(["type": .string("boolean")])
                ])
            ]),
            "target": .object(["type": .string("string"), "minLength": .integer(1)]),
            "nonce": .object(["type": .string("string")]),
            "code": .object(["type": .string("string")]),
            "message": .object([
                "type": .string("string"), "maxLength": .integer(Int64(ControlLimits.maxErrorMessage))
            ]),
            "events": diagnosticEvents,
            "from": .object(["enum": .array(AmbientTakeOver.deviceKinds.map(JSONValue.string))])
        ]),
        "allOf": .array([
            commandRule("hello", requires: ["hello"]),
            commandRule("targets", requires: ["targets"]),
            commandRule("select", requires: ["target"]),
            commandRule("subscribe", requires: ["target"]),
            commandRule("unsubscribe", requires: ["target"]),
            commandRule("escape", requires: ["target"]),
            commandRule("ping", requires: ["nonce"]),
            commandRule("pong", requires: ["nonce"]),
            commandRule("error", requires: ["code", "message"]),
            commandRule("diagnostic", requires: ["events"]),
            commandRule("ambient_heard", requires: ["target", "text"]),
            commandRule("ambient_overheard", requires: ["target", "text", "speaker"]),
            commandRule("overheard_scope", requires: ["scope"]),
            commandRule("set_reply_mute", requires: ["muted"]),
            commandRule("owner_voice", requires: ["state"]),
            commandRule("ambient_input", requires: ["route"]),
            commandRule("session_update", requires: ["update", "session", "priority", "text"]),
            commandRule("session_update_cancel", requires: ["update"]),
            commandRule("health_report", requires: ["report"]),
            commandRule("media_mode", requires: ["on"]),
            commandRule("duck_mode", requires: ["on"]),
            commandRule("set_privacy", requires: ["on"]),
            diagnosticPayloadRule,
            stopPlaybackPayloadRule,
            replyYieldPayloadRule,
            ambientMovedHerePayloadRule,
            ambientHeardPayloadRule,
            heardTurnPayloadRule,
            ambientOverheardPayloadRule,
            overheardScopePayloadRule,
            setReplyMutePayloadRule,
            ownerVoicePayloadRule,
            ambientInputPayloadRule,
            sessionUpdatePayloadRule,
            sessionUpdateCancelPayloadRule,
            healthPayloadRule,
            healthReportPayloadRule,
            mediaModePayloadRule,
            duckModePayloadRule,
            setPrivacyPayloadRule
        ])
    ])
}
// swiftlint:enable type_body_length
