import Foundation
import HailProtocol
import Testing
@testable import HailCore
#if os(iOS)
import AVFAudio
#endif

/// The legacy playback-start route identifies the output (#852).
@MainActor
@Suite struct DeviceDiagnosticsOutputRouteTests {
    let suite = "hail-output-route-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    func playbackStart(_ log: DeviceDiagnostics) throws -> DiagnosticEvent {
        log.setEnabled(true)
        let playback = ReplyPlaybackController(player: IdlePlayer())
        playback.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 1))
        #expect(playback.isReplyAudioOutputBusy)
        log.watch(playback)
        log.watch(playback)
        let events = try #require(log.nextBatch()).events.filter { $0.name == .replyPlaybackStart }
        #expect(events.count == 1)
        return try #require(events.first)
    }

    @Test(arguments: ["bluetooth_a2dp", "built_in_speaker", "headphones", "usb_audio", "none", "other"])
    func playbackStartRecordsTheOutputRouteAndRoundTrips(route: String) throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults)
        log.currentAudioRoute = { Self.snapshot(output: DiagnosticRoutePort(rawValue: route) ?? .other) }
        let event = try playbackStart(log)
        #expect(event.fields[.route] == .token(route))
        #expect(DiagnosticField.route.tokens.contains(route))
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
        let frame = Frame(timestamp: 1, source: "phone", payload: .control(.diagnostic(events: [event])))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)).payload == frame.payload)
    }

    static func snapshot(output: DiagnosticRoutePort) -> AudioRouteSnapshot {
        .init(ports: .init(input: .none, output: output, inputCount: 0, outputCount: output == .none ? 0 : 1),
              settings: .init(category: .playback, defaultToSpeaker: false, allowA2DP: false,
                              allowHFP: false, mixWithOthers: true))
    }

    #if os(macOS)
    @Test func macOSPlaybackStartStillHasNoRouteField() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults)
        #expect(try playbackStart(log).fields.isEmpty)
    }
    #endif

    #if os(iOS)
    @Test func outputPortTypesMapToExistingTokens() {
        #expect(DeviceDiagnostics.route(.bluetoothA2DP) == "bluetooth_a2dp")
        #expect(DeviceDiagnostics.route(.builtInSpeaker) == "built_in_speaker")
        #expect(DeviceDiagnostics.route(.headphones) == "headphones")
        #expect(DeviceDiagnostics.route(.usbAudio) == "usb_audio")
        #expect(DeviceDiagnostics.route(AVAudioSession.Port(rawValue: "unmapped_port_type")) == "other")
    }
    #endif
}
