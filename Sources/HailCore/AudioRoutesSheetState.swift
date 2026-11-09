/// The Bluetooth headset microphone option (#905), when this session can apply it.
public struct HFPOption: Equatable, Sendable {
    /// The saved preference. It is off by default.
    public var isOn: Bool
    /// The owner's last apply error, kept until an apply succeeds.
    public var failure: String?

    public init(isOn: Bool, failure: String?) {
        (self.isOn, self.failure) = (isOn, failure)
    }
}

/// What the audio routes sheet asks the audio owner to do (#1115). None of them activates or deactivates audio.
public enum AudioRoutesIntent: Equatable, Sendable {
    /// Prefer this microphone, or automatic selection for `nil`.
    case selectInput(AudioPort.ID?)
    /// Apply the saved preference again after a failure; the preference itself is kept.
    case retryInput
    case setBluetoothHFP(Bool)
}

/// One microphone choice: automatic selection or a port.
public struct AudioRouteChoice: Equatable, Sendable, Identifiable {
    /// The port, or `nil` for automatic selection.
    public let id: AudioPort.ID?
    public let name: String
    public let isPreferred: Bool

    public var intent: AudioRoutesIntent { .selectInput(id) }
}

/// What the audio routes sheet shows (#1115). It is a reading of the audio owner's state: it never activates or
/// deactivates audio, selects a route itself, or treats a route as private.
///
/// - The active microphone comes only from the live session. Inactive audio reads "Audio inactive", never a
///   last-known or preferred input (Jarvis, PR 6 plan).
/// - A failed request stays visible, with Retry, until the owner observes success and its resolution changes.
/// - Choices and Retry need active audio, as the existing microphone menu does, and a disabled reason is visible.
/// - The output is what the session reports playing; the system picker changes it, never the sheet.
/// - The Bluetooth headset row shows only when the session can apply it.
public struct AudioRoutesSheetState: Equatable, Sendable {
    /// The microphone the live session uses, or why there is none.
    public let activeInput: String
    /// The preferred microphone when it isn't the active one: "name · not active" or "name · unavailable".
    public let preferred: String?
    public let status: String
    /// The failed request and why, while the owner reports a failure.
    public let failure: String?
    public let showsRetry: Bool
    public let choices: [AudioRouteChoice]
    public let choicesEnabled: Bool
    /// Shown when the choices and Retry can't be used.
    public let disabledReason: String?
    public let output: String
    public let hfp: HFPOption?

    public static let inactiveReason = "Choose a microphone while audio is active."
    public static let hfpDetail = "While on, AirPods switch to call-quality audio (mono, lower fidelity). It "
        + "applies at once while audio is active, which can interrupt it, or when audio next starts."

    /// The Bluetooth row's caption: the apply error if there is one, otherwise the trade-off.
    public var hfpCaption: String? { hfp.map { $0.failure ?? Self.hfpDetail } }

    /// VoiceOver's reading of the microphone row, with any failure in it.
    public var microphoneAccessibilityLabel: String {
        let parts = ["Microphone, \(activeInput)", preferred.map { "Preferred \($0)" }, failure]
        return parts.compactMap { $0 }.joined(separator: ". ") + "."
    }

    public static func resolve(
        diagnostics: AudioSessionDiagnostics, inputs: [AudioPort], preferred: AudioPort?,
        selection: AudioInputSelectionState, hfp: HFPOption?
    ) -> Self {
        let active = diagnostics.isActive
        let usable = active && !inputs.isEmpty
        let failed = selection.resolution == .failed
        let automatic = AudioRouteChoice(id: nil, name: "Automatic", isPreferred: preferred == nil)
        let ports = inputs.map { AudioRouteChoice(id: $0.id, name: $0.name, isPreferred: $0.id == preferred?.id) }
        return Self(
            activeInput: active ? (diagnostics.input?.name ?? "No microphone active") : "Audio inactive",
            preferred: preferredText(preferred, active: active ? diagnostics.input : nil, inputs: inputs),
            status: active ? status(selection, input: diagnostics.input, preferred: preferred) : "Audio inactive",
            failure: failed ? failureText(selection) : nil,
            showsRetry: failed,
            choices: [automatic] + ports,
            choicesEnabled: usable,
            disabledReason: disabledReason(active: active, usable: usable),
            output: active && !diagnostics.outputs.isEmpty
                ? diagnostics.outputs.map(\.name).joined(separator: ", ") : "System output",
            hfp: hfp)
    }

    private static func disabledReason(active: Bool, usable: Bool) -> String? {
        guard !usable else { return nil }
        return active ? "No microphones are available." : inactiveReason
    }

    private static func preferredText(_ preferred: AudioPort?, active: AudioPort?, inputs: [AudioPort]) -> String? {
        guard let preferred, preferred.id != active?.id else { return nil }
        let available = inputs.contains { $0.id == preferred.id }
        return "\(preferred.name) · \(available ? "not active" : "unavailable")"
    }

    /// The existing status wording for each resolution, with a failure's reason in its own line.
    private static func status(
        _ selection: AudioInputSelectionState, input: AudioPort?, preferred: AudioPort?
    ) -> String {
        switch selection.resolution {
        case .inactive: return "Audio inactive"
        case .automatic: return input.map { "Using \($0.name) automatically" } ?? "No microphone active"
        case .confirmed: return input.map { "Using \($0.name)" } ?? "Preferred microphone is not active"
        case .fallback:
            return "Using \(input?.name ?? "fallback input"); preferred \(preferred?.name ?? "input") unavailable"
        case .failed: return "Microphone needs attention"
        }
    }

    private static func failureText(_ selection: AudioInputSelectionState) -> String {
        let attempted = selection.attempted?.name ?? "automatic selection"
        let reason = selection.failureDescription ?? "route request failed"
        return "Could not apply \(attempted): \(reason)" + (reason.hasSuffix(".") ? "" : ".")
    }
}
