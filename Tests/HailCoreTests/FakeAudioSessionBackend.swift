@testable import HailCore

enum FakeAudioError: Error {
    case selectionFailed
}

actor FakeAudioSessionBackend: AudioSessionBackend {
    static let usb = AudioPort(id: "usb", name: "Wireless Mic Rx", kind: .usb)
    static let builtIn = AudioPort(id: "built-in", name: "iPad Microphone", kind: .builtIn)

    private var inputs: [AudioPort]
    private var selectionFails: Bool
    private var emitsRouteChangeOnSelection = false
    private var replacementInputsOnSelection: [AudioPort]?
    private var holdNextInputLookup = false
    private var heldInputLookup: CheckedContinuation<Void, Never>?
    private var holdNextInputSelection = false
    private var heldInputSelection: CheckedContinuation<Void, Never>?
    private var diagnosticsCallsBeforeHold: Int?
    private var heldDiagnostics: CheckedContinuation<Void, Never>?
    let lifecycleSuspension = FakeAudioLifecycleSuspension()
    private(set) var selectedInput: AudioPort?
    private(set) var selectionCount = 0
    private(set) var activationHistory: [Bool] = []
    private(set) var eventStreamRequestCount = 0
    private var active = false
    private let eventPair = AsyncStream<AudioSessionBackendEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))

    init(inputs: [AudioPort], selectionFails: Bool = false) {
        self.inputs = inputs
        self.selectionFails = selectionFails
    }

    func configure(allowsBluetoothHFP: Bool) async throws {
        await lifecycleSuspension.suspendConfigurationIfNeeded()
    }

    func setActive(_ active: Bool) async throws {
        if active { await lifecycleSuspension.suspendActivationIfNeeded() }
        self.active = active
        activationHistory.append(active)
    }

    func availableInputs() async -> [AudioPort] {
        if holdNextInputLookup {
            holdNextInputLookup = false
            await withCheckedContinuation { continuation in
                heldInputLookup = continuation
            }
        }
        return inputs
    }

    func selectInput(id: AudioPort.ID?) async throws {
        if holdNextInputSelection {
            holdNextInputSelection = false
            await withCheckedContinuation { continuation in
                heldInputSelection = continuation
            }
        }
        if selectionFails { throw FakeAudioError.selectionFailed }
        selectionCount += 1
        selectedInput = inputs.first { $0.id == id }
        if let replacementInputsOnSelection {
            self.replacementInputsOnSelection = nil
            inputs = replacementInputsOnSelection
            if let selectedInput, !inputs.contains(selectedInput) {
                self.selectedInput = nil
            }
            eventPair.continuation.yield(.routeChanged)
            await Task.yield()
        }
        if emitsRouteChangeOnSelection {
            eventPair.continuation.yield(.routeChanged)
            await Task.yield()
        }
    }

    func diagnostics(isActive: Bool) async -> AudioSessionDiagnostics {
        let snapshot = AudioSessionDiagnostics(
            isActive: isActive,
            input: selectedInput,
            outputs: [AudioPort(id: "speaker", name: "Speaker", kind: .other)],
            sampleRate: 48_000
        )
        if let calls = diagnosticsCallsBeforeHold {
            if calls == 0 {
                diagnosticsCallsBeforeHold = nil
                await withCheckedContinuation { continuation in
                    heldDiagnostics = continuation
                }
            } else {
                diagnosticsCallsBeforeHold = calls - 1
            }
        }
        return snapshot
    }

    func eventStream() async -> AsyncStream<AudioSessionBackendEvent> {
        eventStreamRequestCount += 1
        return eventPair.stream
    }

    func replaceInputs(_ inputs: [AudioPort]) {
        self.inputs = inputs
        if let selectedInput, !inputs.contains(selectedInput) {
            self.selectedInput = nil
        }
    }

    func failFutureSelections() { selectionFails = true }

    func emitRouteChangeOnFutureSelections() { emitsRouteChangeOnSelection = true }

    func replaceInputsDuringNextSelection(with inputs: [AudioPort]) {
        replacementInputsOnSelection = inputs
    }

    func holdNextAvailableInputsCall() { holdNextInputLookup = true }

    func waitUntilInputLookupIsHeld() async {
        while heldInputLookup == nil {
            await Task.yield()
        }
    }

    func releaseHeldInputLookup() {
        let continuation = heldInputLookup
        heldInputLookup = nil
        continuation?.resume()
    }

    func holdNextSelectionCall() { holdNextInputSelection = true }

    func waitUntilSelectionIsHeld() async {
        while heldInputSelection == nil {
            await Task.yield()
        }
    }

    func releaseHeldSelection() {
        let continuation = heldInputSelection
        heldInputSelection = nil
        continuation?.resume()
    }

    func holdDiagnosticsCall(after calls: Int) {
        diagnosticsCallsBeforeHold = calls
    }

    func waitUntilDiagnosticsIsHeld() async {
        while heldDiagnostics == nil {
            await Task.yield()
        }
    }

    func releaseHeldDiagnostics() {
        let continuation = heldDiagnostics
        heldDiagnostics = nil
        continuation?.resume()
    }
}

extension AudioPort {
    static let usb = AudioPort(id: "usb", name: "Wireless Mic Rx", kind: .usb)
    static let builtIn = AudioPort(id: "built-in", name: "iPad Microphone", kind: .builtIn)
}

actor VolatileAudioInputPreferenceStore: AudioInputPreferenceStoring {
    private var stored: AudioPort?

    func load() -> AudioPort? { stored }

    func save(_ port: AudioPort?) { stored = port }
}
