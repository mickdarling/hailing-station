import Foundation
import HailCore
import HailDaemonKit
import Testing
@testable import haild

/// Parsing/binding only: no native factory, device, model, credential or service calls.
@Suite struct CoachingProviderBindingTests {
    private var arguments: [String] {
        ["--rightyo", "/authored/child", "--rightyo-config", "/authored/config",
         "--listener-profile", "/authored/profile", "--listener", "coach", "--private-output", "101",
         "--room-microphone", "102", "--renderer-output-root", "/authored/output"]
    }
    private var hosted: [String] {
        ["--coaching-provider", "jev", "--coaching-allow-hosted-text", "--coaching-max-requests", "20",
         "--coaching-advice-catalog", "/authored/catalog"]
    }
    @Test func defaultAndExplicitMockRemainMockWithoutAnyHostedGrant() throws {
        for extra in [[], ["--coaching-provider", "mock"]] {
            let selected = try CoachingConfiguration.parse(arguments + extra)
            let child = selected.childConfiguration(profile: Data(), provenance: .synthetic)
            guard case .mock = selected.provider, case .mock = child.provider else {
                Issue.record("Default changed from mock"); return
            }
            #expect(child.mockSuggestions == nil && child.provenance == .synthetic)
        }
    }
    @Test func explicitConsentBudgetAndCatalogSurviveTheSharedNativeBinderWithoutActivation() throws {
        for budget in ["1", "100"] {
            let selected = try CoachingConfiguration.parse(arguments + ["--coaching-allow-hosted-text",
                "--coaching-advice-catalog", "/authored/catalog", "--coaching-provider", "jev",
                "--coaching-max-requests", budget])
            let child = selected.childConfiguration(profile: Data([17]), provenance: .liveMicrophone)
            guard case let .jev(consent, requests, catalog) = child.provider else {
                Issue.record("Explicit provider silently downgraded"); return
            }
            #expect(consent && requests == Int(budget) && catalog.path == "/authored/catalog")
            #expect(child.profile == Data([17]) && child.provenance == .liveMicrophone)
            #expect(child.mockSuggestions == nil && child.executable == selected.executable)
        }
    }
    @Test func missingMixedRepeatedUnknownAndOrdinaryASRChoicesFailClosed() {
        var invalid: [[String]] = [Array(hosted.dropFirst(2)), Array(hosted.prefix(2)), Array(hosted.dropLast(2)),
            hosted.filter { $0 != "--coaching-allow-hosted-text" }]
        invalid += [hosted + ["--coaching-allow-hosted-text"],
            hosted + ["--coaching-provider", "mock"], hosted + ["--allow-hosted"],
            hosted + ["--use-jev"], hosted + ["--coaching-allow-hosted-text", "true"],
            hosted.replacing("jev", with: "mock"), hosted.replacing("jev", with: "unknown"),
            hosted.replacing("/authored/catalog", with: "catalog"), hosted.replacing("/authored/catalog", with: "\0"),
            hosted.replacing("/authored/catalog", with: "https://invalid.example/catalog")]
        for extra in invalid {
            #expect(throws: CoachingCommandError.invalidConfiguration) {
                try CoachingConfiguration.parse(arguments + extra)
            }
        }
        for budget in ["", "0", "101", "-1", "+1", "1.0", "true", "999999999999999999999999"] {
            #expect(throws: CoachingCommandError.invalidConfiguration) {
                try CoachingConfiguration.parse(arguments + hosted.replacing("20", with: budget))
            }
        }
    }
}

private extension Array where Element == String {
    func replacing(_ value: String, with replacement: String) -> [String] {
        map { $0 == value ? replacement : $0 }
    }
}

/// Same command owner + shared binder + real owned transport, but the executable only records argv.
@Suite(.serialized) @MainActor struct CoachingProviderCommandTests {
    @Test func onlyAwareEnableLaunchesTheExplicitChoiceWithoutImplicitASRConsent() async throws {
        for hosted in [false, true] {
            let rig = try Fixture(hosted: hosted)
            #expect(rig.command.owner.status == .off && !rig.argumentsExist && rig.audioCreations == 0)
            _ = try rig.command.control("status")
            #expect(!rig.argumentsExist)
            _ = try rig.command.control("enable aware")
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while !rig.argumentsExist, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let arguments = try String(contentsOf: rig.record, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(arguments.contains("--coaching") && arguments.contains("--control-fd"))
            #expect(!arguments.contains("--allow-hosted") && !arguments.contains("--use-jev"))
            #expect(arguments.contains("--coaching-provider") == hosted)
            #expect(arguments.contains("--coaching-allow-hosted-text") == hosted)
            if hosted {
                #expect(arguments.contains("jev") && arguments.contains("20") && arguments.contains(rig.catalog.path))
            }
            #expect(rig.command.owner.status == .active && rig.audioCreations == 1 && rig.player.played == 0)
            await rig.command.join()
            #expect(rig.command.owner.status == .off && rig.capture.stops == 1 && rig.speech.calls == 0)
        }
    }
    @Test func incompatibleCatalogIsRefusedBeforeAudioFactoryAndNeverDowngraded() async throws {
        let rig = try Fixture(hosted: true, missingCatalog: true)
        #expect(throws: (any Error).self) { try rig.command.control("enable aware") }
        await rig.command.join()
        #expect(!rig.argumentsExist && rig.audioCreations == 0 && rig.player.played == 0)
    }

    @MainActor private final class Fixture {
        let record: URL, catalog: URL
        let capture = ExecutableCoachingCapture(), player = ExecutablePrivatePlayer(), speech = ExecutableMockSpeech()
        var audioCreations = 0
        var argumentsExist: Bool { FileManager.default.fileExists(atPath: record.path) }
        private var owner: CoachingCommand?
        var command: CoachingCommand {
            guard let owner else { preconditionFailure("Incomplete authored fixture") }; return owner
        }
        init(hosted: Bool, missingCatalog: Bool = false) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("coaching-binding-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            record = root.appendingPathComponent("arguments"); catalog = root.appendingPathComponent("catalog")
            let executable = root.appendingPathComponent("authored-child")
            let config = root.appendingPathComponent("config")
            let profile = root.appendingPathComponent("profile")
            try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(record.path)'\nexec /bin/sleep 60\n".utf8)
                .write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try Data("{}".utf8).write(to: config)
            if !missingCatalog { try Data("{\"step\":\"Ask for the next step.\"}".utf8).write(to: catalog) }
            try Self.profile.write(to: profile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.path)
            let selected = try CoachingConfiguration.parse(Self.arguments(root: root, hosted: hosted))
            let data = try selected.loadProfile()
            owner = try CoachingCommand(listener: selected.listenerID, transport: { hooks, flags in
                try CoachingChildTransport(selected.childConfiguration(profile: data, provenance: .synthetic),
                                           hooks: hooks, activityFlags: flags)
            }, audio: { [unowned self] hooks in
                audioCreations += 1
                let resource = try ExecutablePrivateAudio(capture: capture, player: player, hooks: hooks)
                return CoachingCommandAudio(owner: resource, playback: { .idle })
            }, speech: speech)
        }
        private static var profile: Data {
            Data("""
            {"version":1,"listener_id":"coach","name":"Coach","domain":"Authored","speak_when":"Pause",\
            "stay_quiet_when":"Busy","delivery":"owner_private","priority":0,"cooldown_ms":0}
            """.utf8)
        }
        private static func arguments(root: URL, hosted: Bool) -> [String] {
            let arguments = ["--rightyo", root.appendingPathComponent("authored-child").path, "--rightyo-config",
                root.appendingPathComponent("config").path, "--listener-profile",
                root.appendingPathComponent("profile").path,
                "--listener", "coach", "--private-output", "101", "--room-microphone", "102",
                "--renderer-output-root", root.appendingPathComponent("unused-output").path]
            return arguments + (hosted ? ["--coaching-provider", "jev", "--coaching-allow-hosted-text",
                "--coaching-max-requests", "20", "--coaching-advice-catalog",
                root.appendingPathComponent("catalog").path] : [])
        }
    }
}
