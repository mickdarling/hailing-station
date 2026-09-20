import AVFoundation
import Observation
import UIKit

/// Spike #22: can this device record from a USB mic (DJI receiver) while playing through AirPods over A2DP?
/// A throwaway probe; the production audio session is #4. Every step appends to `log`, which is the raw
/// material for the result table in `docs/devices.md`.
@MainActor
@Observable
final class RoutingProbe {
    enum Mode: String, CaseIterable {
        case standard = "default"
        case voiceChat
    }

    var mode: Mode = .standard
    private(set) var log = ""
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var observer: (any NSObjectProtocol)?
    private let session = AVAudioSession.sharedInstance()
    private let fileURL = FileManager.default.temporaryDirectory.appending(path: "probe.caf")

    /// Called when the screen goes away: stop, drop the observer, and leave no audio behind (#45).
    func tearDown() {
        recorder?.stop()
        player?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        try? FileManager.default.removeItem(at: fileURL)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// `.playAndRecord` + A2DP only (no HFP, so the AirPods stay output-only) + USB port as preferred input.
    func configure() {
        do {
            let sessionMode: AVAudioSession.Mode = mode == .voiceChat ? .voiceChat : .default
            try session.setCategory(.playAndRecord, mode: sessionMode, options: [.allowBluetoothA2DP])
            try session.setActive(true)
            let usb = session.availableInputs?.first { $0.portType == .usbAudio }
            try session.setPreferredInput(usb)
            append("configured playAndRecord/\(mode.rawValue), A2DP only, preferred input \(describe(usb))")
            append("available inputs: \(list(session.availableInputs ?? []))")
            logRoute("after configure")
            observeRouteChanges()
        } catch {
            append("configure failed: \(error)")
        }
    }

    func record(seconds: Int = 10) async {
        guard recorder?.isRecording != true else {
            append("already recording")
            return
        }
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            self.recorder = recorder
            guard recorder.record() else {
                append("record() returned false")
                return
            }
            defer { recorder.stop() }
            logRoute("recording")
            for second in 1...seconds {
                try await Task.sleep(for: .seconds(1))
                recorder.updateMeters()
                append("t=\(second)s peak=\(Int(recorder.peakPower(forChannel: 0))) dBFS")
            }
            append("recorded \(seconds)s")
        } catch {
            append("record failed: \(error)")
        }
    }

    func play() {
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            self.player = player
            player.play()
            logRoute("playing \(Int(player.duration))s")
        } catch {
            append("play failed: \(error)")
        }
    }

    func logRoute(_ label: String) {
        let route = session.currentRoute
        append("\(label): in=\(list(route.inputs)) out=\(list(route.outputs)) rate=\(Int(session.sampleRate))")
    }

    func copyLog() {
        let device = UIDevice.current
        UIPasteboard.general.string = "\(device.model) \(device.systemName) \(device.systemVersion)\n\(log)"
    }

    private func observeRouteChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor in self?.logRoute("route change (reason \(reason))") }
        }
    }

    private func describe(_ port: AVAudioSessionPortDescription?) -> String {
        port.map { "\($0.portType.rawValue) \"\($0.portName)\"" } ?? "none (no usbAudio port present)"
    }

    private func list(_ ports: [AVAudioSessionPortDescription]) -> String {
        ports.isEmpty ? "[]" : ports.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ", ")
    }

    private func append(_ line: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        log += "[\(stamp)] \(line)\n"
        print("probe \(line)")
    }
}
