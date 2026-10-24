import Foundation
import HailProtocol
import Testing
@testable import HailCore
#if os(iOS)
import AVFAudio
#endif

/// Playback-start output diagnostics (#852), independent of the input-only route-change event.
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
        log.outputRoute = { route }
        let event = try playbackStart(log)
        #expect(event.fields[.route] == .token(route))
        #expect(DiagnosticField.route.tokens.contains(route))
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
        let frame = Frame(timestamp: 1, source: "phone", payload: .control(.diagnostic(events: [event])))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)).payload == frame.payload)
    }

    @Test func anUnmappedOutputIsRecordedOnlyAsOther() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults)
        log.outputRoute = { "unmapped_port_type" }
        #expect(try playbackStart(log).fields[.route] == .token("other"))
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
