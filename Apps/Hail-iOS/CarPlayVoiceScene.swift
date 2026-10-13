import SwiftUI

// CarPlay spike (#72), simulator only. Everything that touches CarPlay compiles only when HAIL_CARPLAY is set, which
// only the docs/carplay/simulator.md build sets; the normal and TestFlight builds see the no-op modifier below and nothing else.
// The voice-based conversational entitlement has not been granted, so this never ships as is.

extension View {
    /// Mirrors the station's listen/speak state to the CarPlay voice template; a no-op without HAIL_CARPLAY.
    func carPlayVoiceState(listening: Bool, speaking: Bool) -> some View {
        #if HAIL_CARPLAY
        onChange(of: CarPlayVoicePhase(listening: listening, speaking: speaking), initial: true) { _, phase in
            CarPlayVoiceBridge.shared.phase = phase
        }
        #else
        self
        #endif
    }
}

#if HAIL_CARPLAY
import CarPlay
import UIKit

enum CarPlayVoicePhase: String, CaseIterable {
    case idle, listening, speaking

    init(listening: Bool, speaking: Bool) {
        self = speaking ? .speaking : listening ? .listening : .idle
    }

    /// Short and spoken-style: the guide says not to show text in response to queries, so only the state shows.
    var voiceState: CPVoiceControlState {
        switch self {
        case .idle: CPVoiceControlState(identifier: rawValue, titleVariants: ["Haili is ready", "Ready"],
                                        image: UIImage(systemName: "waveform"), repeats: false)
        case .listening: CPVoiceControlState(identifier: rawValue, titleVariants: ["Listening…", "Listening"],
                                             image: UIImage(systemName: "mic.fill"), repeats: true)
        case .speaking: CPVoiceControlState(identifier: rawValue, titleVariants: ["Haili is speaking", "Speaking"],
                                            image: UIImage(systemName: "speaker.wave.2.fill"), repeats: true)
        }
    }
}

/// The single hand-off point between the phone's existing pipeline and the CarPlay scene. CarPlay reads it; it
/// owns no audio, connection or queue of its own, so it cannot bypass the destination's authorization.
@MainActor
final class CarPlayVoiceBridge {
    static let shared = CarPlayVoiceBridge()
    var phase = CarPlayVoicePhase.idle {
        didSet { if phase != oldValue { onChange?(phase) } }
    }
    var onChange: ((CarPlayVoicePhase) -> Void)?
}

/// Declares the CarPlay scene dynamically, so Info.plist (generated from project.yml) stays unchanged.
final class CarPlayAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .carTemplateApplication {
            configuration.delegateClass = CarPlayVoiceSceneDelegate.self
        }
        return configuration
    }
}

final class CarPlayVoiceSceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var voiceTemplate: CPVoiceControlTemplate?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        // Voice first on launch: a one-row root, with the voice template presented over it at once.
        let item = CPListItem(text: "Talk to Haili", detailText: nil, image: UIImage(systemName: "waveform"))
        item.handler = { [weak self] _, completion in
            self?.presentVoice()
            completion()
        }
        let root = CPListTemplate(title: "Hailing Station", sections: [CPListSection(items: [item])])
        interfaceController.setRootTemplate(root, animated: false) { [weak self] _, _ in self?.presentVoice() }
        CarPlayVoiceBridge.shared.onChange = { [weak self] phase in self?.show(phase) }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CarPlayVoiceBridge.shared.onChange = nil
        self.interfaceController = nil
        voiceTemplate = nil
    }

    private func presentVoice() {
        guard let interfaceController, voiceTemplate == nil else { return }
        let template = CPVoiceControlTemplate(voiceControlStates: CarPlayVoicePhase.allCases.map(\.voiceState))
        voiceTemplate = template
        interfaceController.presentTemplate(template, animated: true) { [weak self] _, _ in
            self?.show(CarPlayVoiceBridge.shared.phase)
        }
    }

    private func show(_ phase: CarPlayVoicePhase) {
        voiceTemplate?.activateVoiceControlState(withIdentifier: phase.rawValue)
    }
}
#endif
