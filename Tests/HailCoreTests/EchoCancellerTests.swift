import Testing
import HailCore

struct EchoCancellerTests {
    let format = EchoPCMFormat(sampleRate: 48_000, channels: 2)

    @Test func privateRoutePreservesInterleavedSamplesAndFrameLength() throws {
        let processor = PassthroughEchoCanceller()
        #expect(processor.diagnostics.requiresMasking)
        try processor.configure(format: format)
        #expect(processor.outputLatencySamples == 0)
        let reference = EchoPCMFrame(format: format, startSample: 100, samples: [31, -31])
        try processor.render(reference: reference)
        let capture = EchoPCMFrame(format: format, startSample: 100, samples: [.min, 1, -1, .max])
        let result = try processor.process(capture: capture)
        #expect(result.frame == capture)
        #expect(result.frame.samples.count == 4)
        #expect(result.diagnostics == EchoDiagnostics(state: .ready))
        #expect(!result.diagnostics.requiresMasking)
    }

    @Test func invalidConfigurationAndFramesFailClosedUntilReconfigured() throws {
        let processor = PassthroughEchoCanceller()
        let good = EchoPCMFrame(format: format, startSample: 100, samples: [10, 20])
        #expect(throws: EchoCancellerError.unconfigured) { try processor.process(capture: good) }
        for bad in [EchoPCMFormat(sampleRate: 0, channels: 1), EchoPCMFormat(sampleRate: 1, channels: 0)] {
            try processor.configure(format: format)
            #expect(throws: EchoCancellerError.unsupportedFormat) { try processor.configure(format: bad) }
            #expect(processor.diagnostics.requiresMasking)
            #expect(throws: EchoCancellerError.unsupportedFormat) { try processor.process(capture: good) }
        }
        let mono = EchoPCMFormat(sampleRate: 48_000, channels: 1)
        for bad in [EchoPCMFrame(format: format, startSample: 100, samples: []),
                    EchoPCMFrame(format: format, startSample: 100, samples: [1]),
                    EchoPCMFrame(format: mono, startSample: 50, samples: [1, 2])] {
            try processor.configure(format: format)
            #expect(throws: EchoCancellerError.invalidFrame) { try processor.render(reference: bad) }
            #expect(processor.diagnostics == EchoDiagnostics(state: .failed(.invalidFrame)))
            #expect(throws: EchoCancellerError.invalidFrame) { try processor.process(capture: good) }
            try processor.configure(format: format)
            #expect(throws: EchoCancellerError.invalidFrame) { try processor.process(capture: bad) }
        }
        processor.reset()
        #expect(processor.diagnostics == EchoDiagnostics(state: .unconfigured))
        #expect(throws: EchoCancellerError.unconfigured) { try processor.render(reference: good) }
    }

    @Test func diagnosticsAreIndependentOfPCMAndContainOnlyHealthMetrics() throws {
        let processor = PassthroughEchoCanceller()
        try processor.configure(format: format)
        var startSample: Int64 = 100
        for samples: [Int16] in [[0, 0], [.min, .max], [33, -75, 113, 57]] {
            let frame = EchoPCMFrame(format: format, startSample: startSample, samples: samples)
            startSample = try #require(frame.endSample)
            let result = try processor.process(capture: frame)
            #expect(result.diagnostics == EchoDiagnostics(state: .ready))
            #expect(result.diagnostics.estimatedDelayMilliseconds == nil)
            #expect(result.diagnostics.coarseERLEDecibels == nil)
        }
        #expect(EchoDiagnostics(state: .adapting).requiresMasking)
        processor.reset()
        #expect(processor.diagnostics.requiresMasking)
    }
}

struct EchoCancellerRegistryTests {
    @Test func defaultSelectionFollowsPlatformAndActualRouteClass() {
        let registry = EchoCancellerRegistry()
        for platform in EchoPlatform.allCases {
            guard case .implementation(.frames(let processor)) = registry.resolve(
                platform: platform, route: .verifiedPrivateHeadphones
            ) else { Issue.record("Qualified private output requires a frame processor"); continue }
            #expect(processor is PassthroughEchoCanceller)
            guard case .mask(.unconfiguredRoute) = registry.resolve(platform: platform, route: .unknown)
            else { Issue.record("Unqualified output must mask"); continue }
            for route in [EchoRouteClass.roomSpeaker, .roomHandsFree, .otherRoomOutput] {
                let selection = registry.resolve(platform: platform, route: route)
                switch (platform, selection) {
                case (.mac, .mask(.unregisteredImplementation)), (.iPadAppOnMac, .mask(.unregisteredImplementation)):
                    break
                case (.iPhone, .implementation(.inGraph(let graph))), (.iPad, .implementation(.inGraph(let graph))):
                    #expect(graph.requirement == .voiceProcessingWithSameEngineReplies)
                default: Issue.record("Unexpected room-output selection")
                }
            }
        }
    }

    @Test func explicitUnknownRouteMappingStillMasks() {
        let configuration = EchoCancellerConfiguration(identifiers: [.mac: [.unknown: "none"]])
        let resolution = EchoCancellerRegistry().resolve(platform: .mac, route: .unknown, configuration: configuration)
        guard case .mask(.unconfiguredRoute) = resolution else {
            Issue.record("Configuration must never unmask an unknown route")
            return
        }
    }

    @Test func desktopRoomDefaultsResolveTheReservedIdentifierWhenRegistered() {
        var registry = EchoCancellerRegistry()
        registry.register("aec3") { .frames(ReferencePairingProbe()) }
        for platform in [EchoPlatform.mac, .iPadAppOnMac] {
            for route in [EchoRouteClass.roomSpeaker, .roomHandsFree, .otherRoomOutput] {
                guard case .implementation(.frames(let processor)) = registry.resolve(platform: platform, route: route)
                else { Issue.record("Expected the registered desktop processor"); continue }
                #expect(processor is ReferencePairingProbe)
            }
        }
    }

    @Test func configuredReplacementUsesTheSameFrameInterface() throws {
        var registry = EchoCancellerRegistry()
        let configuration = EchoCancellerConfiguration(identifiers: [.mac: [.roomSpeaker: "test-reference"]])
        func resolve() -> EchoCancellerResolution {
            registry.resolve(platform: .mac, route: .roomSpeaker, configuration: configuration)
        }
        guard case .mask(.unregisteredImplementation) = resolve() else {
            Issue.record("Missing configured processor must mask")
            return
        }
        registry.register("test-reference") { .frames(ReferencePairingProbe()) }
        guard case .implementation(.frames(let processor)) = resolve(),
              case .implementation(.frames(let otherRun)) = resolve() else {
            Issue.record("Expected configured processor")
            return
        }
        let format = EchoPCMFormat(sampleRate: 16_000, channels: 1)
        let input = EchoPCMFrame(format: format, startSample: 100, samples: [42])
        try processor.configure(format: format)
        try processor.render(reference: EchoPCMFrame(format: format, startSample: 100, samples: [12]))
        let result = try processor.process(capture: input)
        #expect(result.frame == EchoPCMFrame(format: format, startSample: 100, samples: [12]))
        #expect(result.diagnostics == EchoDiagnostics(state: .ready, estimatedDelayMilliseconds: 20,
                                                     coarseERLEDecibels: 10))
        #expect(otherRun.diagnostics == EchoDiagnostics(state: .unconfigured))
        processor.reset()
        #expect(processor.diagnostics == EchoDiagnostics(state: .unconfigured))
    }

    @Test func graphHasNoFrameCapabilityAndRequiresFreshConfirmation() {
        let registry = EchoCancellerRegistry()
        guard case .implementation(.inGraph(let graph)) = registry.resolve(platform: .iPhone, route: .roomSpeaker)
        else { Issue.record("Expected graph wiring"); return }
        #expect(!(graph is any FrameEchoCanceller))
        #expect(graph.requirement == .voiceProcessingWithSameEngineReplies)
        #expect(graph.diagnostics.requiresMasking)
        graph.reportRequirementMet(true)
        #expect(!graph.diagnostics.requiresMasking)
        graph.reportRequirementMet(false)
        #expect(graph.diagnostics == EchoDiagnostics(state: .failed(.graphUnavailable)))
        #expect(graph.diagnostics.requiresMasking)
        graph.reset()
        #expect(graph.diagnostics == EchoDiagnostics(state: .unconfigured))
    }
}
