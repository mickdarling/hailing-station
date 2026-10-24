#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Meeting-only rig settings keep the existing event callback as the sole trailing closure of `ambientRig`.
struct MeetingTestSettings: Sendable {
    var timeout: TimeInterval = AmbientRightyoRouter.defaultMeetingTimeout
    var onChange: (@Sendable (UUID, Bool, MeetingProfile, String) -> Void)?
}

/// A reference around the noncopyable mutex, captured by the hook without borrowing a half-initialized rig.
private final class MeetingChanges: Sendable {
    let list = Mutex<[(UUID, String)]>([])
}

/// A one-way latch a test opens; work queued behind it on a chain waits (bounded) until it is open.
final class MeetingLatch: Sendable {
    private let opened = Mutex(false)
    var isOpen: Bool { opened.withLock { $0 } }
    func open() { opened.withLock { $0 = true } }
    func wait() async { _ = await eventually { self.isOpen } }
}

/// Synthetic enrolled meeting turns through the loopback listener (#735 meeting mode (rightyo#227)). A marker
/// releases the second turn only after the test heard the first confirmation; no timing inference separates them.
final class MeetingRig: Sendable {
    static let on = AmbientAckClip(pcm: Data(repeating: 6, count: 480), sampleRate: 24_000,
                                  text: "Meeting mode on. I'll stay quiet unless you ask me by name.")
    static let off = AmbientAckClip(pcm: Data(repeating: 7, count: 480), sampleRate: 24_000, text: "Meeting mode off.")
    static let ended = AmbientAckClip(pcm: Data(repeating: 8, count: 480), sampleRate: 24_000,
                                     text: "Meeting mode ended.")
    static let privacyOn = AmbientAckClip(pcm: Data(repeating: 9, count: 480), sampleRate: 24_000,
                                         text: "Privacy on. I'm only listening for my name.")
    static var clips: AmbientAckLibrary {
        AmbientAckLibrary(clips: [AmbientStopConfirmation.meetingOn: [on], AmbientStopConfirmation.meetingOff: [off],
                                 AmbientStopConfirmation.meetingEnded: [ended]])
    }
    /// The meeting clips and "Privacy on.", for a privacy entry racing a meeting's clip.
    static var privacyClips: AmbientAckLibrary {
        AmbientAckLibrary(clips: [AmbientStopConfirmation.meetingOn: [on], AmbientStopConfirmation.meetingOff: [off],
                                 AmbientStopConfirmation.meetingEnded: [ended],
                                 AmbientStopConfirmation.privacyOn: [privacyOn]])
    }
    let fake: FakeRightyo
    let env: AmbientWiringRig
    let pair: FallbackSocketPair
    let stream = UUID()
    private let events = DuckEvents()
    private let hooks = MeetingChanges()
    var changeConnections: [UUID] { hooks.list.withLock { $0.map(\.0) } }
    var changes: [String] { hooks.list.withLock { $0.map(\.1) } }
    var socket: URLSessionWebSocketTask { pair.sockets[0] }

    init(phrases: [String] = ["meeting mode"], timeout: TimeInterval = AmbientRightyoRouter.defaultMeetingTimeout,
         clips: AmbientAckLibrary? = MeetingRig.clips) async throws {
        let second = phrases.count > 1 ? """
        n=0
        while [ ! -e next-turn ] && [ $n -lt 300 ]; do /bin/sleep 0.05; n=$((n + 1)); done
        /usr/bin/sed "s/formed-demo/$7/g" off.jsonl
        """ : ""
        fake = try FakeRightyo(FakeRightyo.ackingControl(append: true) + "\n"
            + "/usr/bin/sed -e '$d' -e \"s/formed-demo/$7/g\" events.jsonl\n" + second + "\n"
            + FakeRightyo.ackingTail)
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        try Self.prepare(fake, phrases: phrases)
        let events = events, hooks = hooks
        env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: clips,
                                   replyControl: true, startDeadline: 30, ackDeadline: 30,
                                   meeting: .init(timeout: timeout, onChange: { connection, on, profile, reason in
            hooks.list.withLock { $0.append((connection, "on=\(on) profile=\(profile.rawValue) reason=\(reason)")) }
        }), onEvent: { event in events.list.withLock { $0.append(event) } })
        pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        try await recipientSocketSend(audio(stream, 0), on: socket)
    }

    private static func prepare(_ fake: FakeRightyo, phrases: [String]) throws {
        let original = try fake.recorded("events.jsonl").split(separator: "\n").map(String.init)
        var lines = original.map { $0.replacingOccurrences(of: "Rightyo, archive the project.",
                                                          with: "Rightyo, \(phrases[0]).") }
        lines[0] = lines[0].replacingOccurrences(of: "\"phase\": \"started\"",
            with: "\"addressing\": {\"names\": [\"Rightyo\"]}, \"duck\": {\"version\": 3}, \"phase\": \"started\"")
        try (lines.joined(separator: "\n") + "\n").write(to: fake.directory.appendingPathComponent("events.jsonl"),
                                                         atomically: true, encoding: .utf8)
        guard phrases.count > 1 else { return }
        let second = original[3...5].enumerated().map { index, line in
            line.replacingOccurrences(of: "Rightyo, archive the project.", with: "Rightyo, \(phrases[1]).")
                .replacingOccurrences(of: "\"utterance_id\": \"request\"", with: "\"utterance_id\": \"request-two\"")
                .replacingOccurrences(of: "formed-demo:request", with: "formed-demo:request-two")
                .replacingOccurrences(of: "\"sequence\": \(index + 4)", with: "\"sequence\": \(index + 7)")
        }
        try (second.joined(separator: "\n") + "\n").write(to: fake.directory.appendingPathComponent("off.jsonl"),
                                                          atomically: true, encoding: .utf8)
    }

    func connection() -> UUID? { env.router.activeConnection() }
    func details(_ name: String) -> [String] {
        events.list.withLock { $0.filter { $0.event == name }.map { $0.detail ?? "" } }
    }
    /// Every later child of the fake replays its turns; from now on its first says an ordinary request instead, so
    /// a new or reloaded child does not repeat the meeting command (a renewal) on its own.
    func quietLaterChildren() throws {
        let url = fake.directory.appendingPathComponent("events.jsonl")
        let events = try String(contentsOf: url, encoding: .utf8)
        try events.replacingOccurrences(of: "Rightyo, meeting mode.", with: "Rightyo, archive the project.")
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func releaseOff() throws { try Data().write(to: fake.directory.appendingPathComponent("next-turn")) }
    /// Waits (bounded) for every hook and clip queued on the meeting chain so far: a sentinel queued behind them.
    func drainMeetingChanges() async {
        let drained = MeetingLatch()
        env.router.meetingChanges.enqueue { drained.open() }
        #expect(await eventually { drained.isOpen }, "meeting chain drained marker")
    }
    func confirmation() async throws -> String? {
        for _ in 0..<6 {
            let frame = try await receiveFrame(on: socket, step: "meeting confirmation")
            if case .text(let words) = frame.payload {
                // The clip's audio follows its words (`acknowledgementFrames`): taken too, so a barrier sees none.
                let audio = try await receiveFrame(on: socket, step: "meeting confirmation audio")
                if case .audio(let pcm) = audio.payload, pcm.reply?.id == words.reply?.id {} else {
                    Issue.record("expected the confirmation's own audio")
                }
                return words.text
            }
            if case .audio = frame.payload {} else { Issue.record("expected confirmation audio") }
        }
        Issue.record("no meeting confirmation text within six frames")
        return nil
    }
    func finish() async {
        try? releaseOff()
        try? await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await boundedSettle(env.router, step: "meeting rig settle")
        await bounded("meeting listener stop") { [listener = env.listener] in
            await listener.stop(reason: "synthetic test complete")
        }
    }
    func close() { pair.close(); fake.cleanUp() }
    static func lines(_ values: Bool...) -> String { values.map { "{\"media\":\($0)}\n" }.joined() }
}
#endif
