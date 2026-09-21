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
    private(set) var selectedInput: AudioPort?
    private(set) var selectionCount = 0
    private(set) var activationHistory: [Bool] = []
    private var active = false
    private let eventPair = AsyncStream<AudioSessionBackendEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))

    init(inputs: [AudioPort], selectionFails: Bool = false) {
        self.inputs = inputs
        self.selectionFails = selectionFails
    }

    func configure(allowsBluetoothHFP: Bool) async throws {}

    func setActive(_ active: Bool) async throws {
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
        AudioSessionDiagnostics(
            isActive: isActive,
            input: selectedInput,
            outputs: [AudioPort(id: "speaker", name: "Speaker", kind: .other)],
            sampleRate: 48_000
        )
    }

    func eventStream() async -> AsyncStream<AudioSessionBackendEvent> {
        eventPair.stream
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
}

extension AudioPort {
    static let usb = AudioPort(id: "usb", name: "Wireless Mic Rx", kind: .usb)
    static let builtIn = AudioPort(id: "built-in", name: "iPad Microphone", kind: .builtIn)
}
