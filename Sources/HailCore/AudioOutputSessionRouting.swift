// swiftlint:disable file_length
// The platform adapter and scripted tests use the same effect runner.
#if os(iOS)
import AVFoundation
import Foundation

/// AVFoundation translation and effects only; the shared pure policy owns the decisions (#852).
@MainActor
final class AudioOutputSessionRouting {
    static let shared = AudioOutputSessionRouting(.sharedInstance())
    let driver = AudioOutputRouteDriver()
    let session: AVAudioSession
    private let observers = NotificationObserverBag()
    private var deferred: [AudioOutputRoutePolicy.Route] = []
    private var performing = false

    init(_ session: AVAudioSession) {
        self.session = session
        observers.add(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                             object: session, queue: .main) { [weak self] note in
            let snapshot = AudioOutputSessionRouting.snapshot(note)
            MainActor.assumeIsolated { self?.changed(snapshot) }
        })
        observers.add(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                object: session, queue: .main) { [weak self] note in
            guard note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ==
                    AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.interrupted() }
        })
    }

    private func interrupted() {
        driver.ownership.isActive = false
        driver.ownership.awaitingInputSelection = false
    }

    private func changed(_ snapshot: Snapshot) {
        var route = current(snapshot)
        if performing {
            if route.reason != .newDeviceAvailable, route.reason != .oldDeviceUnavailable {
                route.origin = driver.writing
            }
            deferred.append(route)
        } else {
            process(route)
        }
    }

    private func process(_ route: AudioOutputRoutePolicy.Route) {
        performing = true
        run(route)
        if let observation = driver.lastObservation, observation.status == .noWrite {
            AVAudioSessionBackend.logRouteDecision(observation.reason)
        }
        drain()
    }

    private func run(_ route: AudioOutputRoutePolicy.Route) {
        driver.routeChanged(route, actual: { self.current() }, perform: { try Self.apply($0, to: self.session) },
                            inputs: standaloneInputs, select: selectStandalone)
    }

    private func drain() {
        while !deferred.isEmpty {
            let next = deferred.removeFirst()
            run(next)
        }
        performing = false
    }

    func write(_ operation: AudioOutputRoutePolicy.Operation, _ body: () throws -> Void) rethrows {
        let outermost = !performing
        performing = true
        defer { if outermost { drain() } }
        try driver.write(operation, before: current(), actual: { self.current() }, perform: body)
    }

    private func current(_ snapshot: Snapshot = .init(reasonRaw: 0, previousInputs: [], previousOutputs: []))
        -> AudioOutputRoutePolicy.Route {
        var route = Self.route(session, snapshot: snapshot)
        route.owner = driver.ownership.owner
        route.isActive = driver.ownership.isActive
        route.awaitingInputSelection = driver.ownership.awaitingInputSelection
        return route
    }
}

extension AudioOutputSessionRouting {
    struct Snapshot: Sendable {
        let reasonRaw: UInt
        let previousInputs: [AudioOutputRoutePolicy.Port]
        let previousOutputs: [AudioOutputRoutePolicy.Port]
    }

    nonisolated static func snapshot(_ notification: Notification) -> Snapshot {
        let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        return Snapshot(
            reasonRaw: notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0,
            previousInputs: portTypes(previous?.inputs ?? []), previousOutputs: portTypes(previous?.outputs ?? [])
        )
    }

    static func configure(_ session: AVAudioSession, allowsBluetoothHFP _: Bool) throws {
        // Legacy standalone player entry point. Its argument reflects the previous category, not the saved toggle.
        let routing = session === shared.session ? shared : AudioOutputSessionRouting(session)
        if routing.driver.ownership.isActive, routing.driver.ownership.owner == .capture { return }
        try routing.configureStandalone(preferences: .saved())
    }

    func prepareBackendCategory(allowsBluetoothHFP: Bool, source: AudioOutputSessionOwnership.Request) throws {
        try driver.ownership.configure(source, allowsHFP: allowsBluetoothHFP,
                                       category: configure(for:allowsBluetoothHFP:), standalone: configureStandalone)
    }

    private func standaloneInputs() -> (available: [AudioPort], currentID: AudioPort.ID?) {
        ((session.availableInputs ?? []).map(AVAudioSessionBackend.port), session.currentRoute.inputs.first?.uid)
    }

    private func selectStandalone(_ preferred: AudioPort) throws {
        guard let port = session.availableInputs?.first(where: { $0.uid == preferred.id }) else {
            throw AudioInputSelectionError.unavailable(preferred.id)
        }
        // The driver also selects to supersede an unreflected request, even when the live mic already matches.
        try writePreferredInput(port)
    }

    private func configureStandalone(preferences: AudioInputPreferences) throws {
        try driver.configureStandalone(preferences: preferences, prepare: {
            try self.configure(for: .standalone, allowsBluetoothHFP: preferences.allowsBluetoothHFP)
            if !self.driver.ownership.isActive { try self.activate(true) }
        }, inputs: standaloneInputs, select: selectStandalone, reconcile: reconcile)
    }

    func setCaptureActive(_ active: Bool) throws {
        // The settings path ends after configure. Only capture's subsequent activation transfers ownership.
        if active, driver.ownership.owner == .standalone {
            try configure(for: .capture, allowsBluetoothHFP: driver.ownership.standaloneAllowsHFP)
        }
        try activate(active)
    }

    private func configure(for newOwner: AudioOutputRoutePolicy.Owner, allowsBluetoothHFP: Bool) throws {
        let route = current()
        let continuing = route.isActive && newOwner == route.owner && route.category == .playAndRecord
            && !route.options.mixWithOthers
        let desired = AudioOutputRoutePolicy.configurationOptions(
            for: route, owner: newOwner, allowsHFP: allowsBluetoothHFP, state: driver.state
        )
        var options = continuing ? session.categoryOptions : []
        options = Self.applying(desired, to: options)
        options.insert(.allowBluetoothA2DP)
        if desired.allowsHFP { options.insert(.allowBluetoothHFP) } else { options.remove(.allowBluetoothHFP) }
        let otherOptionsMatch = session.categoryOptions.subtracting(.defaultToSpeaker)
            == options.subtracting(.defaultToSpeaker)
        if session.category == .playAndRecord, session.mode == .default, otherOptionsMatch,
           !route.needsSpeakerDefaultChange(to: desired.defaultToSpeaker) {
            driver.ownership.configured(for: newOwner, continuing: continuing, allowsHFP: allowsBluetoothHFP)
            driver.configured(current())
            return
        }
        try write(.configure) {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            driver.ownership.configured(for: newOwner, continuing: continuing, allowsHFP: allowsBluetoothHFP)
        }
        if continuing { reconcile() }
    }

    private func activate(_ active: Bool) throws {
        try write(.activation) {
            try session.setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
            driver.ownership.isActive = active
            driver.ownership.awaitingInputSelection = active
        }
    }

    func select(_ port: AVAudioSessionPortDescription?) throws {
        if session.preferredInput?.uid == port?.uid,
           port == nil || session.currentRoute.inputs.first?.uid == port?.uid { return }
        try writePreferredInput(port)
    }

    private func writePreferredInput(_ port: AVAudioSessionPortDescription?) throws {
        let type = port.flatMap { Self.portTypes([$0]).first }
        try write(.preferredInput(type)) { try session.setPreferredInput(port) }
        if !driver.ownership.awaitingInputSelection { reconcile() }
    }

    func inputSelectionFinished() {
        guard driver.ownership.awaitingInputSelection else { return }
        driver.ownership.awaitingInputSelection = false
        reconcile()
    }

    func reconcile() {
        guard driver.ownership.isActive, !driver.ownership.awaitingInputSelection else { return }
        var route = current()
        route.settling = true
        process(route)
    }

    func keepalive(_ active: Bool, operation: AudioOutputRoutePolicy.Operation, _ body: () throws -> Void) rethrows {
        try write(operation) {
            try body()
            driver.ownership.isActive = active
            driver.ownership.owner = active ? .keepalive : .unownedSession
            driver.ownership.awaitingInputSelection = false
        }
    }

    static func route(_ session: AVAudioSession, snapshot: Snapshot) -> AudioOutputRoutePolicy.Route {
        let current = session.currentRoute
        let category: AudioOutputRoutePolicy.Category = session.category == .playAndRecord ? .playAndRecord
            : (session.category == .playback ? .playback : .other)
        return AudioOutputRoutePolicy.Route(
            category: category, options: policyOptions(session.categoryOptions),
            categoryOptions: session.categoryOptions.rawValue,
            outputs: portTypes(current.outputs), inputs: portTypes(current.inputs),
            availableInputs: portTypes(session.availableInputs ?? []),
            previousOutputs: snapshot.previousOutputs,
            previousInputs: snapshot.previousInputs, reason: reason(snapshot.reasonRaw)
        )
    }

    static func apply(_ effect: AudioOutputRouteDriver.Effect, to session: AVAudioSession) throws {
        switch effect {
        case .setCategory(let desired):
            try session.setCategory(
                session.category, mode: session.mode, options: applying(desired, to: session.categoryOptions)
            )
        case .restoreSpeaker:
            try session.overrideOutputAudioPort(.speaker)
        case .clearOverride:
            try session.overrideOutputAudioPort(.none)
        }
    }

    nonisolated private static func portTypes(
        _ descriptions: [AVAudioSessionPortDescription]
    ) -> [AudioOutputRoutePolicy.Port] {
        let ports: [AVAudioSession.Port: AudioOutputRoutePolicy.Port] = [
            .builtInSpeaker: .speaker, .builtInReceiver: .receiver, .builtInMic: .builtInMic,
            .bluetoothA2DP: .bluetoothA2DP, .bluetoothLE: .bluetoothLE, .bluetoothHFP: .bluetoothHFP,
            .headphones: .headphones, .headsetMic: .headsetMic, .usbAudio: .usbAudio,
            .lineIn: .lineIn, .lineOut: .lineOut, .HDMI: .hdmi,
            .airPlay: .airPlay, .carAudio: .carAudio
        ]
        return descriptions.map { ports[$0.portType] ?? .other }
    }

    private static func policyOptions(_ options: AVAudioSession.CategoryOptions) -> AudioOutputRoutePolicy.Options {
        .init(defaultToSpeaker: options.contains(.defaultToSpeaker), mixWithOthers: options.contains(.mixWithOthers),
              allowsA2DP: options.contains(.allowBluetoothA2DP), allowsHFP: options.contains(.allowBluetoothHFP))
    }

    private static func applying(
        _ desired: AudioOutputRoutePolicy.Options, to options: AVAudioSession.CategoryOptions
    ) -> AVAudioSession.CategoryOptions {
        var result = options
        if desired.defaultToSpeaker { result.insert(.defaultToSpeaker) } else { result.remove(.defaultToSpeaker) }
        return result
    }

    private static func reason(_ raw: UInt) -> AudioOutputRoutePolicy.Reason {
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .newDeviceAvailable: .newDeviceAvailable
        case .oldDeviceUnavailable: .oldDeviceUnavailable
        case .override: .override
        case .categoryChange: .categoryChange
        case .routeConfigurationChange: .routeConfigurationChange
        default: .other
        }
    }
}
#endif

/// The settings backend also configures standalone replies when capture is idle.
struct AudioOutputSessionOwnership {
    var owner = AudioOutputRoutePolicy.Owner.unownedSession
    var isActive = false
    var awaitingInputSelection = false
    var standaloneAllowsHFP = false

    enum Request { case capturePreparation, idleSetting }

    func configure(_ source: Request, allowsHFP: Bool, category: (AudioOutputRoutePolicy.Owner, Bool) throws -> Void,
                   standalone: (AudioInputPreferences) throws -> Void) rethrows {
        if isActive, owner == .standalone, source == .idleSetting {
            try standalone(.init(allowsBluetoothHFP: allowsHFP))
        } else {
            try category(isActive && owner == .standalone ? .standalone : .capture, allowsHFP)
        }
    }

    mutating func configured(for newOwner: AudioOutputRoutePolicy.Owner, continuing: Bool, allowsHFP: Bool) {
        if newOwner == .standalone { standaloneAllowsHFP = allowsHFP }
        owner = newOwner
        if !continuing && newOwner == .capture { awaitingInputSelection = true }
    }
}

/// Runs on the session owner's executor. Tests supply the same route snapshots and synchronous effect boundary.
final class AudioOutputRouteDriver {
    typealias Policy = AudioOutputRoutePolicy
    enum Effect: Equatable, Sendable {
        case setCategory(Policy.Options)
        case clearOverride, restoreSpeaker

        var operation: Policy.Operation {
            switch self {
            case .setCategory: .repairCategory
            case .clearOverride: .releaseOverride
            case .restoreSpeaker: .restoreSpeaker
            }
        }
    }

    enum Status: Sendable { case noWrite, applied, failed }
    enum Trigger: Sendable {
        case notification(Policy.Reason), settlement, operation(Policy.Operation)
    }

    /// One observation per notification, reconciliation, or lifecycle operation. Only port types leave the adapter.
    struct Observation: Sendable {
        let trigger: Trigger
        let reason: Policy.DecisionReason
        let userChoseBuiltIn: Bool
        let attribution: Policy.Operation?
        let effect: Policy.Operation?
        let status: Status
        let before: Policy.Pair
        let actual: Policy.Route
    }

    var ownership = AudioOutputSessionOwnership()
    var state = Policy.State()
    private struct PendingInput {
        let id: AudioPort.ID
        let generation: Int
        let alreadyOnTarget: Bool
    }

    private var pendingInput: PendingInput?
    private var supersededInput: PendingInput?
    private(set) var writing: Policy.Operation?
    private(set) var lastObservation: Observation?
    var observe: ((Observation) -> Void)?

    private func publish(_ observation: Observation) {
        lastObservation = observation
        observe?(observation)
    }

    func configureStandalone(preferences: AudioInputPreferences, prepare: () throws -> Void,
                             inputs: () -> (available: [AudioPort], currentID: AudioPort.ID?),
                             select: (AudioPort) throws -> Void, reconcile: () -> Void) rethrows {
        do {
            ownership.awaitingInputSelection = true
            defer { ownership.awaitingInputSelection = false }
            try prepare()
            try resolveInput(preferences: preferences, inputs: inputs, select: select)
        }
        if pendingInput == nil { reconcile() }
    }

    func routeChanged(_ event: Policy.Route, actual: () -> Policy.Route, perform: (Effect) throws -> Void,
                      inputs: () -> (available: [AudioPort], currentID: AudioPort.ID?),
                      select: (AudioPort) throws -> Void) {
        // Observe the hardware episode first, including any release of the speaker choice.
        guard process(event, actual: actual, perform: perform) else { return }
        let live = actual()
        if live.category == .playback, live.options.mixWithOthers,
           ownership.owner == .standalone || ownership.owner == .capture {
            // The keepalive can take the native session without calling the station's configuration entry point.
            ownership = .init()
            pendingInput = nil
            supersededInput = nil
        }
        guard event.owner == .standalone, live.owner == .standalone, live.isActive,
              live.category == .playAndRecord, !live.options.mixWithOthers else { return }
        let confirmation = event.inputs == live.inputs &&
            (event.reason == .routeConfigurationChange || event.reason == .override)
        let currentID = inputs().currentID
        let confirmed = observePendingInput(currentID: currentID, confirmation: confirmation)
        let hardware = event.reason == .newDeviceAvailable || event.reason == .oldDeviceUnavailable
        guard !live.awaitingInputSelection, state.skippedOutputs == nil, !state.ambiguousEpisode else { return }
        if confirmed { reconcileInput(actual: actual, perform: perform) }
        let staleConfirmation = confirmation && event.reason == .routeConfigurationChange &&
            supersededInput?.generation == state.hardwareGeneration && supersededInput?.id == currentID
        guard hardware || staleConfirmation else { return }
        if supersededInput?.generation != state.hardwareGeneration || staleConfirmation {
            supersededInput = nil
        }
        let changedInput: Bool
        do {
            ownership.awaitingInputSelection = true
            defer { ownership.awaitingInputSelection = false }
            let preferences = AudioInputPreferences(allowsBluetoothHFP: ownership.standaloneAllowsHFP)
            changedInput = try resolveInput(preferences: preferences, inputs: inputs, select: select)
        } catch {
            // select records the refused session write. A later hardware event may retry it.
            return
        }
        if changedInput, pendingInput == nil { reconcileInput(actual: actual, perform: perform) }
    }

    private func reconcileInput(actual: () -> Policy.Route, perform: (Effect) throws -> Void) {
        var settled = actual()
        settled.reason = .other
        settled.settling = true
        process(settled, actual: actual, perform: perform)
    }

    @discardableResult
    private func observePendingInput(currentID: AudioPort.ID?, confirmation: Bool = false) -> Bool {
        guard let request = pendingInput else { return false }
        // A replacement can start on its target. The pre-write pair cannot confirm that the old request was displaced.
        let confirmed = currentID == request.id && (!request.alreadyOnTarget || confirmation)
        if confirmed || request.generation != state.hardwareGeneration { pendingInput = nil }
        return confirmed
    }

    @discardableResult
    private func resolveInput(preferences: AudioInputPreferences,
                              inputs: () -> (available: [AudioPort], currentID: AudioPort.ID?),
                              select: (AudioPort) throws -> Void) rethrows -> Bool {
        let ports = inputs()
        let eligible = ports.available.filter { $0.kind != .bluetoothHFP || !state.holdsBuiltInOutput }
        observePendingInput(currentID: ports.currentID)
        guard let preferred = preferences.resolve(from: eligible),
              pendingInput?.id != preferred.id else { return false }
        // A different outstanding request can still move the mic away from an otherwise correct live pair.
        if pendingInput == nil, preferred.id == ports.currentID { return false }
        let previous = pendingInput
        pendingInput = PendingInput(id: preferred.id, generation: state.hardwareGeneration,
                                    alreadyOnTarget: preferred.id == ports.currentID)
        do {
            try select(preferred)
            // The old request can still report its route after the newer setting already appeared correct.
            if let previous { supersededInput = previous }
            observePendingInput(currentID: inputs().currentID)
            return true
        } catch {
            pendingInput = previous
            throw error
        }
    }
}

extension AudioOutputRouteDriver {
    func configured(_ route: Policy.Route) {
        state.observeOutputs(route.outputs)
        report(.configure, before: route, actual: route, status: .noWrite)
    }

    private func report(_ operation: Policy.Operation, before: Policy.Route, actual: Policy.Route, status: Status) {
        publish(.init(trigger: .operation(operation), reason: .appOperation, userChoseBuiltIn: state.userChoseBuiltIn,
                      attribution: operation, effect: status == .noWrite ? nil : operation, status: status,
                      before: before.pair, actual: actual))
    }

    func write(_ operation: Policy.Operation, before: Policy.Route, actual: () -> Policy.Route,
               perform: () throws -> Void) rethrows {
        do {
            try track(operation, before: before, actual: actual, perform: perform)
            report(operation, before: before, actual: actual(), status: .applied)
        } catch {
            report(operation, before: before, actual: actual(), status: .failed)
            throw error
        }
    }

    private func track(_ operation: Policy.Operation, before: Policy.Route, actual: () -> Policy.Route,
                       perform: () throws -> Void) rethrows {
        state.observeOutputs(before.outputs)
        state.failedSettlement = nil
        writing = operation
        defer { writing = nil }
        try perform()
        let after = actual()
        if operation == .activation || operation == .handoff || operation == .keepalive {
            pendingInput = nil
            supersededInput = nil
        }
        state.transitions.removeAll { $0.operation == .releaseOverride }
        if operation == .configure, before.options.allowsHFP != after.options.allowsHFP {
            let sameHeadset = state.lastArrival?.observedBluetoothOutput == true
            state.lastArrival?.enabledHFP = after.options.allowsHFP && sameHeadset
        }
        state.observeOutputs(after.outputs)
        state.completed(.init(operation: operation, before: before.pair, after: after.pair))
    }
}

extension AudioOutputRouteDriver {
    @discardableResult
    func process(_ route: Policy.Route, actual: () -> Policy.Route, perform: (Effect) throws -> Void) -> Bool {
        let decision = Policy.routeChange(route, state: state)
        state = decision.state
        var status = Status.noWrite
        var attempted: Policy.Operation?
        var completed = true
        for effect in effects(for: decision, route: route) {
            let before = actual()
            guard stillNeeded(effect, for: route, live: before) else {
                // Reconsider the actual pair on its next notification. No later step may use this stale decision.
                completed = false
                state.lastSettled = nil
                let retry = before.owner == route.owner && !before.outputs.contains(where: \.isExternalOutput)
                state.skippedOutputs = retry ? route.outputs : nil
                break
            }
            attempted = effect.operation
            do {
                try track(effect.operation, before: before, actual: actual, perform: { try perform(effect) })
                if decision.reason == .speakerFallback, state.disconnectFallback == .waitingForReceiver {
                    state.disconnectFallback = .applied
                    state.needsSettlement = false
                    state.skippedOutputs = nil
                }
                status = .applied
            } catch {
                completed = false
                if decision.settlesPair { state.failedSettlement = route.pair }
                status = .failed
                break
            }
        }
        if completed, decision.settlesPair {
            state.lastSettled = route.pair
            state.failedSettlement = nil
        }
        publish(.init(trigger: route.settling ? .settlement : .notification(route.reason), reason: decision.reason,
                      userChoseBuiltIn: state.userChoseBuiltIn, attribution: decision.attribution, effect: attempted,
                      status: status, before: route.pair, actual: actual()))
        return status != .failed
    }

    private func stillNeeded(_ effect: Effect, for route: Policy.Route, live: Policy.Route) -> Bool {
        guard live.owner == route.owner, live.owner == .standalone || live.owner == .capture,
              live.category == .playAndRecord, !live.options.mixWithOthers,
              live.isActive, !live.awaitingInputSelection else { return false }
        switch effect {
        case .clearOverride:
            // A category write may move only the mic. Release while the live output is still built-in.
            return !state.holdsBuiltInOutput && live.outputs == route.outputs && !live.outputs.isEmpty
        case .setCategory(let desired):
            return live.outputs == route.outputs && live.options.defaultToSpeaker != desired.defaultToSpeaker
        case .restoreSpeaker:
            return live.outputs == route.outputs && live.outputs != [.speaker]
        }
    }

    private func effects(for decision: Policy.Decision, route: Policy.Route) -> [Effect] {
        var effects: [Effect] = []
        if decision.options != route.options { effects.append(.setCategory(decision.options)) }
        if decision.clearOverride { effects.append(.clearOverride) }
        if decision.restoreSpeaker { effects.append(.restoreSpeaker) }
        return effects
    }
}
