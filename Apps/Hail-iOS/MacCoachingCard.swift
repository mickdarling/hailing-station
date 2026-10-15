#if os(macOS)
import HailCoaching
import HailCore
import SwiftUI

/// Local private coaching uses the same station window and qualified runtime, with capture initially off (#266).
struct MacCoachingCard: View {
    let playback: ReplyPlaybackController
    @Environment(CoachingCaptureExclusion.self) private var exclusion
    @State private var captureOwner: UUID?
    @Environment(LocalCoachingController.self) private var controller
    @State private var microphones: [MacCoachingDevice] = []
    @State private var outputs: [MacCoachingDevice] = []
    @State private var microphone: UInt32 = 0
    @State private var output: UInt32 = 0
    @State private var awareness = false
    @State private var ownerListening = false
    @State private var feedback: String?

    var body: some View {
        StationPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(status).font(.headline).accessibilityIdentifier("station.coaching-status")
                Picker("Room microphone", selection: $microphone) {
                    Text("Choose a microphone").tag(UInt32(0))
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                }
                .disabled(controller.state != .off)
                Picker("Private output", selection: $output) {
                    Text("Choose headphones").tag(UInt32(0))
                    ForEach(outputs) { Text($0.name).tag($0.id) }
                }
                .disabled(controller.state != .off)
                Toggle("Participants know listening is on", isOn: $awareness)
                    .disabled(controller.state != .off)
                Toggle("I'm listening; allow coaching cues", isOn: $ownerListening)
                    .disabled(controller.state != .active)
                    .onChange(of: ownerListening) { _, listening in
                        guard controller.state == .active else { return }
                        do { try controller.setOwnerListening(listening) } catch {
                            feedback = "Coaching stopped. Start a fresh session."
                            let token = captureOwner
                            requestStop(token)
                        }
                    }
                HStack {
                    Button("Start", systemImage: "ear") { start() }
                        .disabled(controller.state != .off || !awareness || microphone == 0 || output == 0)
                        .accessibilityIdentifier("station.coaching-start")
                    Button("Stop", systemImage: "stop.fill") {
                        let token = captureOwner
                        requestStop(token)
                    }
                        .disabled(controller.state == .off)
                        .accessibilityIdentifier("station.coaching-stop")
                    Button("Refresh devices") { refresh() }.disabled(controller.state != .off)
                }
                .buttonStyle(.bordered)
                Text("Local transcription. Private headphone cues. Spoken goal editing is not connected yet.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let feedback = feedback ?? controller.lastFailure?.message {
                    Text(feedback).font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("station.coaching-failure")
                }
            }
        } label: {
            Label("Private coaching", systemImage: "ear.badge.waveform")
        }
        .task { refresh() }
        .onDisappear {
            let token = captureOwner
            requestStop(token)
        }
        .onChange(of: controller.state) { _, state in
            if state == .off {
                awareness = false; ownerListening = false
                if let token = captureOwner { release(token) }
            }
        }
    }

    private var status: String {
        switch controller.state {
        case .off: "Off — microphone closed"
        case .active: "Listening"
        case .stopping: "Stopping…"
        case .refused: "Coaching could not start"
        }
    }

    private func refresh() {
        microphones = MacCoachingDeviceInventory.microphones()
        outputs = MacCoachingDeviceInventory.privateOutputs()
        if !microphones.contains(where: { $0.id == microphone }) { microphone = 0 }
        if !outputs.contains(where: { $0.id == output }) { output = 0 }
    }

    private func start() {
        feedback = nil
        ownerListening = false
        var attempt: UUID?
        var controllerAttempted = false
        do {
            guard let selectedMic = microphones.first(where: { $0.id == microphone }),
                  let selectedOutput = outputs.first(where: { $0.id == output }),
                  MacCoachingDeviceInventory.microphones().contains(selectedMic),
                  MacCoachingDeviceInventory.privateOutputs().contains(selectedOutput) else {
                feedback = "Devices changed. Refresh and choose them again."
                return
            }
            guard !playback.isCaptureSuppressed, !playback.isReplyAudioOutputBusy else {
                feedback = "Stop the other listening or reply before starting private coaching."
                return
            }
            let settings = try MacCoachingSettings.load()
            let token = UUID()
            guard exclusion.claim(token) else {
                feedback = "Another listening session is starting or stopping."
                return
            }
            attempt = token
            captureOwner = token
            CapturePlaybackSuppression.begin(token, using: playback)
            let arguments = try settings.arguments(microphone: microphone, output: output)
            controllerAttempted = true
            try controller.start(arguments: arguments,
                                 participantAwareness: awareness)
        } catch {
            feedback = controllerAttempted ? controller.lastFailure?.message
                : "Local coaching setup could not load. Check its configuration and hosted-text approval."
            if let token = attempt { requestStop(token) }
        }
    }
    private func requestStop(_ token: UUID?) {
        let command = controller, expected = controller.revision
        let admission = exclusion, player = playback
        Task {
            await command.stop(expectedRevision: expected)
            guard let token else { return }
            CapturePlaybackSuppression.end(token, using: player, resuming: true)
            admission.release(token)
            if captureOwner == token { captureOwner = nil }
        }
    }

    private func release(_ token: UUID) {
        CapturePlaybackSuppression.end(token, using: playback, resuming: true)
        exclusion.release(token)
        if captureOwner == token { captureOwner = nil }
    }
}
#endif
