import AVKit
import SwiftUI

/// Apple's route picker owns arbitrary output selection; AVAudioSession can only request speaker/default.
struct AudioOutputRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .secondaryLabel
        picker.activeTintColor = .systemIndigo
        picker.accessibilityLabel = "Choose audio output"
        picker.accessibilityHint = "Opens the system audio output list."
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
