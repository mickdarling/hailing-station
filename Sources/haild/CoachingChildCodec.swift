import AVFAudio
import CoreFoundation
import Foundation
import HailCore
import HailDaemonKit

enum CoachingChildError: Error { case invalidControl, invalidOutput, invalidPCM }

/// Trusted local measured evidence only; no role/name/transcript interpretation supplies these flags.
struct CoachingMeasuredActivity {
    let pauseMilliseconds: Int
    let ownerMidAnswer: Bool
    let playback: Bool
}

enum CoachingChildCodec {
    static func identifier(_ value: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_. -")
        return (1...96).contains(value.count) && value.allSatisfy(allowed.contains)
    }

    static func wire(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 8_192, data.allSatisfy({ $0 < 128 }) else { throw CoachingChildError.invalidControl }
        return data
    }

    static func profile(_ data: Data, listenerID: String) throws -> Data {
        let fields: Set<String> = ["version", "listener_id", "name", "domain", "speak_when",
                                   "stay_quiet_when", "delivery", "priority", "cooldown_ms"]
        guard data.count <= 7_000, identifier(listenerID),
              let profile = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(profile.keys) == fields, integer(profile["version"]) == 1,
              profile["listener_id"] as? String == listenerID, profile["delivery"] as? String == "owner_private",
              let priority = integer(profile["priority"]), (-100...100).contains(priority),
              let cooldown = integer(profile["cooldown_ms"]), (0...60_000).contains(cooldown),
              ["name", "domain", "speak_when", "stay_quiet_when"].allSatisfy({ key in
                  guard let value = profile[key] as? String else { return false }
                  return !value.isEmpty && value.utf8.count <= 1_024
                      && value.utf8.allSatisfy { (32...126).contains($0) }
              }) else { throw CoachingChildError.invalidControl }
        return try wire(["version": 1, "type": "listener_profile", "action": "add", "profile": profile])
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return number as? Int
    }

    static func control(_ action: String, session: UUID, fields: [String: Any] = [:]) throws -> Data {
        try wire(["schema_version": 1, "type": "coaching_control", "action": action,
                  "session_id": session.uuidString.lowercased()].merging(fields) { first, _ in first })
    }

    /// Floor, never extend, the original host deadline; queue acceptance does not prove receipt.
    static func milliseconds(until deadline: ContinuousClock.Instant, at now: ContinuousClock.Instant) -> Int {
        let value = now.duration(to: deadline).components
        return Int(max(0, min(2_000, value.seconds * 1_000 + value.attoseconds / 1_000_000_000_000_000)))
    }

    static func activity(_ measurement: CoachingMeasuredActivity, utterance: String,
                         lease: CoachingQualification) throws -> Data {
        guard identifier(utterance), (0...60_000).contains(measurement.pauseMilliseconds) else {
            throw CoachingChildError.invalidControl
        }
        return try wire(["schema_version": 1, "type": "coaching_activity",
            "session_id": lease.sessionID.uuidString.lowercased(),
            "generation_id": lease.generation.uuidString.lowercased(), "utterance_id": utterance,
            "pause_ms": measurement.pauseMilliseconds, "owner_mid_answer": measurement.ownerMidAnswer,
            "playback": measurement.playback])
    }

    static func finalID(_ object: [String: Any], session: String, provenance: RightyoAudioProvenance) throws -> String {
        guard let emitted = object["emitted_at_ms"] as? Int, emitted >= 0,
              let turn = object["turn"] as? [String: Any], turn["finalized"] as? Bool == true,
              turn["session_id"] as? String == session, let utterance = turn["utterance_id"] as? String,
              identifier(utterance), let revision = turn["revision"] as? Int, revision > 0,
              let start = turn["start_ms"] as? Int, let end = turn["end_ms"] as? Int,
              start >= 0, end >= start, end <= emitted,
              let text = turn["text"] as? String, !text.isEmpty, text.count <= 4_000, text.utf8.count <= 16_000,
              let recognizer = turn["recognizer_id"] as? String, identifier(recognizer),
              turn["provenance"] as? String == provenance.rawValue,
              provenance != .synthetic || (recognizer == "synthetic-authored-v1"
                  && turn["speaker_provenance"] as? String == "authored-fixture") else {
            throw CoachingChildError.invalidOutput
        }
        return utterance
    }
}

/// Pure bounded conversion. No engine/session/device operation; one fixed format per child lifetime.
@MainActor final class CoachingPCMEncoder {
    private var converter: AVAudioConverter?
    func encode(_ snapshot: AudioCaptureBuffer) throws -> Data {
        let input = snapshot.pcmBuffer, format = input.format
        guard format.sampleRate.isFinite, (16_000...192_000).contains(format.sampleRate),
              (1...2).contains(format.channelCount), input.frameLength > 0,
              Double(input.frameLength) <= format.sampleRate / 4, format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved, let channels = input.floatChannelData else {
            throw CoachingChildError.invalidPCM
        }
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(input.frameLength) where !channels[channel][frame].isFinite {
                throw CoachingChildError.invalidPCM
            }
        }
        if let converter, converter.inputFormat != format { throw CoachingChildError.invalidPCM }
        if converter == nil {
            guard let output = AmbientAudioFormat.outputFormat(),
                  let created = AVAudioConverter(from: format, to: output)
            else { throw CoachingChildError.invalidPCM }
            created.downmix = true; converter = created
        }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4_096)
        else { throw CoachingChildError.invalidPCM }
        let supplied = CoachingPCMInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            state.pointee = supplied.used ? .noDataNow : .haveData
            defer { supplied.used = true }
            return supplied.used ? nil : supplied.buffer
        }
        guard status != .error, error == nil, output.frameLength <= 4_096,
              let samples = output.int16ChannelData else { throw CoachingChildError.invalidPCM }
        return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    }
}

private final class CoachingPCMInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var used = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

struct CoachingActivityFlags { let ownerMidAnswer: Bool, playback: Bool }

/// Measured pause from the same actual converted capture stream, never text or speaker attribution.
@MainActor final class CoachingCaptureActivity {
    private(set) var voiceBuffers = 0
    private var lastVoice: ContinuousClock.Instant?
    private var lastCapture: ContinuousClock.Instant?
    func observe(_ data: Data, at now: ContinuousClock.Instant = .now) {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else { return }
        lastCapture = now
        let bytes = Array(data)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let sample = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            if abs(Int(sample)) >= 1_000 { voiceBuffers += 1; lastVoice = now; return }
        }
    }
    func measure(_ flags: CoachingActivityFlags, at now: ContinuousClock.Instant = .now)
        -> CoachingMeasuredActivity? {
        guard let lastVoice, let lastCapture, now >= lastCapture, now >= lastVoice,
              now - lastCapture < .milliseconds(250) else { return nil }
        let pause = lastVoice.duration(to: now).components
        let milliseconds = Int(min(60_000, pause.seconds * 1_000 + pause.attoseconds / 1_000_000_000_000_000))
        return CoachingMeasuredActivity(pauseMilliseconds: milliseconds,
                                        ownerMidAnswer: flags.ownerMidAnswer, playback: flags.playback)
    }
}
