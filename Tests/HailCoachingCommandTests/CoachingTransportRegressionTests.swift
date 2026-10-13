import Foundation
import HailCore
import HailDaemonKit
import Testing
@testable import haild

@Suite(.serialized) @MainActor struct CoachingTransportRegressionTests {
    @Test func explicitHostedTextProviderOptionsReachOnlyExistingOwnedChildArgv() async throws {
        let rig = try CoachingTransportRig(tail: "", hosted: true)
        try await rig.run()
        let arguments = try String(contentsOf: rig.argumentsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.contains("--coaching-provider") && arguments.contains("jev"))
        #expect(arguments.contains("--coaching-allow-hosted-text") && arguments.contains("--coaching-max-requests"))
        #expect(arguments.contains("20") && arguments.contains("--coaching-advice-catalog"))
        #expect(!arguments.contains("--allow-hosted") && !arguments.contains("--use-jev"))
        #expect(rig.driver.status == .active && rig.player.played == 0)
        try await rig.join()
    }
    @Test func supportedDescriptiveVoiceNeverGrantsActivityOrRetiresOwner() async throws {
        let rig = try CoachingTransportRig(tail: """
        printf '{"schema_version":1,"type":"owner_voice","session_id":"%s",\
        "sequence":2,"emitted_at_ms":0,"state":"recognized"}\\n' "$session"
        """)
        try await rig.run()
        #expect(rig.driver.status == .active && rig.capture.stops == 0)
        #expect(rig.flagsCalls == 0 && rig.transport?.finalCount == 0 && rig.player.played == 0)
        try await rig.join()
    }

    @Test func renewalInsideActivityCallbackHoldsOldFinalWithoutRetiringRenewedOwner() async throws {
        let rig = try CoachingTransportRig(tail: CoachingTransportRig.final, renew: true)
        try await rig.run()
        #expect(rig.flagsCalls == 1 && rig.transport?.finalCount == 1)
        #expect(rig.driver.status == .active && rig.capture.stops == 0 && rig.player.played == 0)
        #expect(rig.audio?.session.qualification != rig.original)
        try await rig.join()
    }

    @Test func callbackOffCannotPublishActivityOrPlayback() async throws {
        let rig = try CoachingTransportRig(tail: CoachingTransportRig.final, off: true)
        try await rig.run()
        #expect(rig.flagsCalls == 1 && rig.driver.status != .active && rig.player.played == 0)
        try await rig.join()
    }

    @Test func actionWrongSequenceAndDuplicateFinalStillRetire() async throws {
        let action = """
        printf '{"schema_version":1,"type":"request","session_id":"%s","sequence":2,"emitted_at_ms":0}\\n' "$session"
        """
        for tail in [action, CoachingTransportRig.final.replacingOccurrences(of: "\"sequence\":2",
                                                                             with: "\"sequence\":9"),
                     CoachingTransportRig.final + "\n" + CoachingTransportRig.final.replacingOccurrences(
                        of: "\"sequence\":2", with: "\"sequence\":3")] {
            let rig = try CoachingTransportRig(tail: tail)
            try await rig.run()
            #expect(rig.driver.status != .active && rig.player.played == 0)
            try await rig.join()
        }
    }

    @Test func profileIntegersRejectBooleanAndFloatingScalarsBeforeChildStart() throws {
        for field in ["version", "priority", "cooldown_ms"] {
            for value in ["true", "false", "1.0", "1.5"] {
                let original = field == "version" ? "1" : "0"
                let data = Data(CoachingTransportRig.profile.replacingOccurrences(
                    of: "\"\(field)\":\(original)", with: "\"\(field)\":\(value)").utf8)
                #expect(throws: CoachingChildError.invalidControl) {
                    try CoachingChildCodec.profile(data, listenerID: "coach")
                }
            }
        }
    }
}

/// Real owned child and public coordinator; only authored shell output and generated PCM are used.
@MainActor private final class CoachingTransportRig {
    static let profile = """
    {"version":1,"listener_id":"coach","name":"Coach","domain":"Authored","speak_when":"Pause",\
    "stay_quiet_when":"Busy","delivery":"owner_private","priority":0,"cooldown_ms":0}
    """
    static let final = """
    printf '{"schema_version":1,"type":"transcript","session_id":"%s","sequence":2,"emitted_at_ms":500,\
    "turn":{"session_id":"%s","utterance_id":"live-1","revision":1,"start_ms":0,"end_ms":500,\
    "text":"Authored conversation only","speaker_id":null,"finalized":true,"overlap":false,\
    "recognizer_id":"synthetic-authored-v1","provenance":"synthetic",\
    "speaker_provenance":"authored-fixture"}}\\n' "$session" "$session"
    """
    let capture = ExecutableCoachingCapture(), player = ExecutablePrivatePlayer(), speech = ExecutableMockSpeech()
    var driver: ForegroundCoaching {
        guard let owner else { preconditionFailure("Authored fixture incomplete") }; return owner
    }
    private var owner: ForegroundCoaching?
    var transport: CoachingChildTransport?, audio: ExecutablePrivateAudio?
    var flagsCalls = 0
    var heartbeat: (@MainActor () -> Void)?
    var original: CoachingQualification?
    let argumentsFile: URL

    init(tail: String, renew: Bool = false, off: Bool = false, hosted: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hailing-coaching-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let executable = root.appendingPathComponent("authored-child"), config = root.appendingPathComponent("config")
        argumentsFile = root.appendingPathComponent("arguments")
        let catalog = root.appendingPathComponent("catalog")
        try Data("{\"step\":\"Ask for the next step.\"}".utf8).write(to: catalog)
        try Data(Self.script(record: argumentsFile, tail: tail).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("{}".utf8).write(to: config)
        let configuration = CoachingChildTransport.Configuration(executable: executable, config: config,
            profile: Data(Self.profile.utf8), listenerID: "coach", provenance: .synthetic, mockSuggestions: nil,
            provider: hosted ? .jev(hostedTextConsent: true, maxRequests: 20, adviceCatalog: catalog) : .mock)
        owner = try ForegroundCoaching(listenerID: "coach", transport: { [unowned self] hooks in
            let child = try CoachingChildTransport(configuration, hooks: hooks, activityFlags: { [unowned self] in
                flagsCalls += 1
                if renew { heartbeat?() }
                if off { driver.off() }
                return .init(ownerMidAnswer: false, playback: false)
            })
            transport = child; return child
        }, audio: { [unowned self] hooks in
            let audio = try ExecutablePrivateAudio(capture: capture, player: player, hooks: hooks)
            self.audio = audio; return audio
        }, speech: speech, clock: CoachingClock(schedule: { [weak self] _, fire in
            self?.heartbeat = fire; return {}
        }))
    }
    private static func script(record: URL, tail: String) -> String {
        """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(record.path)'
        session=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--session-id' ]; then shift; session="$1"; fi
          shift
        done
        printf '{"schema_version":1,"type":"session","phase":"started","session_id":"%s",\
        "sequence":1,"emitted_at_ms":0}\\n' "$session"
        /bin/sleep 0.3
        \(tail)
        exec /bin/sleep 60
        """
    }
    func run() async throws {
        try driver.enable(participantAwareness: true)
        original = audio?.session.qualification
        for index in 0..<8 { try capture.send(tone: index == 0); try await Task.sleep(for: .milliseconds(100)) }
    }
    func join() async throws {
        driver.off()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while driver.status != .off, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(driver.status == .off)
    }
}
