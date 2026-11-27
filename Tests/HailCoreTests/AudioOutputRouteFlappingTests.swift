import Testing
@testable import HailCore

struct AudioOutputRouteFlappingTests {
    typealias Policy = AudioOutputRoutePolicy

    private struct Change: Equatable {
        let reason: Policy.Reason
        let previous: Policy.Port
        let current: Policy.Port
    }

    @Test func repeatedAirPodsLossAndReturnWritesOnlyTheFirstSpeakerFallback() {
        // Start at the first removal: built-in mic, A2DP allowed, speaker default and mixing off.
        // Replay the reducer's port/reason samples. Later option values come from our own effects.
        var session = RecordingSession(live: .init(category: .playAndRecord, mode: "default", options: [.a2dp]))
        var state = Policy.State()
        let removed: Policy.Reason = .oldDeviceUnavailable, arrived: Policy.Reason = .newDeviceAvailable
        let speaker: Policy.Port = .speaker, airPods: Policy.Port = .bluetoothA2DP
        let changes: [Change] = [
            .init(reason: removed, previous: airPods, current: speaker),
            .init(reason: arrived, previous: speaker, current: airPods),
            .init(reason: .categoryChange, previous: airPods, current: speaker),
            .init(reason: removed, previous: airPods, current: speaker),
            .init(reason: arrived, previous: speaker, current: airPods),
            .init(reason: .categoryChange, previous: airPods, current: airPods),
            .init(reason: .categoryChange, previous: speaker, current: airPods),
            .init(reason: removed, previous: airPods, current: speaker),
            .init(reason: arrived, previous: speaker, current: airPods),
            .init(reason: .categoryChange, previous: speaker, current: airPods),
            .init(reason: removed, previous: airPods, current: speaker),
            .init(reason: arrived, previous: speaker, current: airPods),
            .init(reason: .routeConfigurationChange, previous: airPods, current: speaker),
            .init(reason: removed, previous: airPods, current: speaker),
            .init(reason: arrived, previous: speaker, current: airPods),
            .init(reason: removed, previous: airPods, current: airPods),
            .init(reason: arrived, previous: speaker, current: airPods),
            .init(reason: removed, previous: airPods, current: speaker)
        ]
        for change in changes {
            let route = Policy.Route(
                options: .init(defaultToSpeaker: session.live.options.contains(.speaker)),
                outputs: [change.current], inputs: [.builtInMic], previousOutputs: [change.previous],
                previousInputs: [.builtInMic], reason: change.reason
            )
            AudioOutputRouteDriver.process(route, state: &state) { session.apply($0) }
        }
        #expect(session.writes == [[.a2dp, .speaker]])
        #expect(session.clears == 0)
    }

    @Test(arguments: [false, true])
    func removalWithAnUnknownOutputPreservesTheLiveDefault(_ enabled: Bool) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = enabled
        session.send(.init(outputs: [.other], inputs: [.builtInMic], previousOutputs: [.bluetoothA2DP],
                           previousInputs: [.builtInMic], reason: .oldDeviceUnavailable))
        #expect(session.effects.isEmpty)
        #expect(session.options.defaultToSpeaker == enabled)
    }

    private enum Option: Hashable { case a2dp, speaker, hfp, mix, other }
    private struct Settings: Equatable {
        let category: Policy.Category
        let mode: String
        var options: Set<Option>

        var categorySettings: AudioOutputRouteDriver.CategorySettings<Policy.Category, String, Set<Option>> {
            .init(category: category, mode: mode, options: options)
        }
    }

    private struct RecordingSession {
        var live: Settings
        var writes: [Set<Option>] = []
        var clears = 0

        mutating func apply(_ effect: AudioOutputRouteDriver.Effect) {
            switch effect {
            case .clearOverride: clears += 1
            case .setCategory(let desired):
                var target = live
                if desired.defaultToSpeaker {
                    target.options.insert(.speaker)
                } else {
                    target.options.remove(.speaker)
                }
                setCategory(target)
            }
        }

        mutating func setCategory(_ target: Settings) {
            AudioOutputRouteDriver.writeCategoryIfNeeded(
                target.categorySettings, live: live.categorySettings, playAndRecord: .playAndRecord, allowA2DP: [.a2dp]
            ) { options in
                writes.append(options)
                live = .init(category: target.category, mode: target.mode, options: options)
            }
        }
    }

    @Test func configureAndKeepaliveRestoreIncludeA2DP() {
        let playback = Settings(category: .playback, mode: "default", options: [.mix])
        let saved = Settings(category: .playAndRecord, mode: "default", options: [.speaker, .hfp, .other])
        var session = RecordingSession(live: saved)
        session.setCategory(playback)
        session.setCategory(saved)
        session.setCategory(.init(category: .playAndRecord, mode: "default", options: []))
        #expect(session.writes == [[.mix], [.a2dp, .speaker, .hfp, .other], [.a2dp]])
    }

    @Test(arguments: [false, true])
    func repairAddsMissingA2DPAndAlwaysClearsTheOverride(_ hasA2DP: Bool) {
        let live = Settings(category: .playAndRecord, mode: "default", options: [.speaker, .hfp])
        var session = RecordingSession(live: live)
        if hasA2DP { session.live.options.insert(.a2dp) }
        var state = Policy.State()
        var repair = AudioOutputRouteEchoTests.repairRoute
        repair.options.defaultToSpeaker = true
        AudioOutputRouteDriver.process(repair, state: &state) { session.apply($0) }
        #expect(session.writes == (hasA2DP ? [] : [[.speaker, .hfp, .a2dp]]))
        #expect(session.clears == 1)
    }

    @Test func skipRequiresMatchingCategoryModeAndEveryResultingOption() {
        let live = Settings(category: .playAndRecord, mode: "default", options: [.a2dp, .hfp])
        let saved = Settings(category: .playAndRecord, mode: "default", options: [.hfp])
        var session = RecordingSession(live: live)
        session.setCategory(live)
        session.setCategory(saved)
        #expect(session.writes.isEmpty)
        session.setCategory(.init(category: .playAndRecord, mode: "voiceChat", options: live.options))
        session.setCategory(.init(category: .playAndRecord, mode: "voiceChat", options: [.a2dp]))
        #expect(session.writes == [live.options, [.a2dp]])
        var mixing = RecordingSession(live: .init(category: .other, mode: "default", options: [.mix]))
        mixing.setCategory(.init(category: .playback, mode: "default", options: [.mix]))
        mixing.setCategory(.init(category: .playback, mode: "default", options: [.mix]))
        #expect(mixing.writes == [[.mix]])
    }
}
