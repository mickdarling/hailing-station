#if os(macOS)
import AppKit
import Darwin
import Foundation
import HailCore
import Observation

/// Runs one `haild coaching --parent-control` child per Start (#645). The child owns the coaching foundation
/// (capture, the RightyO child, speech and the private output). This app sends only control words and reads only
/// content-free status lines. Any other output is dropped unread, so transcript or advice text never reaches
/// the app, and nothing here is logged. Quitting the app closes the pipes, and haild retires coaching on EOF.
@MainActor @Observable
final class MacCoachingController {
    static let shared = MacCoachingController()

    private(set) var model = PrivateCoachingCardModel()
    var state: PrivateCoachingCardState { model.state }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var control: FileHandle?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var pending = Data()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var suppression: (token: UUID, playback: ReplyPlaybackController)?

    /// Awareness (and hosted consent, inside `arguments`) were confirmed in the card just before this call.
    func start(executable: String, arguments: [String], playback: ReplyPlaybackController) {
        guard state.canStart, process == nil else { return }
        model.startRequested()
        let token = UUID()
        suppression = (token, playback)
        CapturePlaybackSuppression.begin(token, using: playback) // Replies wait while coaching holds audio.
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardInput = input
        child.standardError = output
        child.standardOutput = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            // EOF arrives on this same handler after the last line, so the end is never seen before it.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if data.isEmpty { self.exited() } else { self.receive(data) }
            }
        }
        do { try child.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            finish()
            return
        }
        try? output.fileHandleForWriting.close() // Only the child holds these ends, so its exit is our EOF.
        try? input.fileHandleForReading.close()
        process = child
        control = input.fileHandleForWriting
        send("enable aware")
        watchStatusAndFocus()
    }

    private func watchStatusAndFocus() {
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.state.holdsAudio else { return }
                self.send("status") // The child reports a route end only in reply to a control line.
            }
        }
        // The foundation retires on route, sleep and session changes inside the child. Losing the app's focus
        // is the in-process rule it also applies, so the card keeps it for the child.
        for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.stop() }
            })
        }
    }

    func stop() {
        guard state.holdsAudio else { return }
        model.stopRequested()
        send("off")
        send("quit")
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let process = self.process, process.isRunning else { return }
            process.terminate() // Last resort; haild's own retirement normally ends it within a second.
        }
    }

    private func send(_ word: String) {
        guard let control else { return }
        do { try control.write(contentsOf: Data((word + "\n").utf8)) } catch {
            self.control = nil // The child is gone; its EOF finishes the run.
        }
    }

    private func receive(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = String(bytes: pending[pending.startIndex..<newline], encoding: .ascii)
            pending.removeSubrange(pending.startIndex...newline)
            guard let line, let status = PrivateCoachingStatusLine(line) else { continue } // Dropped unread.
            model.received(status)
            if status == .status(.off) { send("quit") } // The run is over; the next Start is a fresh child.
        }
        if pending.count > 512 { pending.removeAll() } // Status lines are short; never hold anything else.
    }

    private func exited() {
        model.childExited()
        finish()
    }

    private func finish() {
        if state.holdsAudio { model.childExited() }
        poll?.cancel(); poll = nil
        watchdog?.cancel(); watchdog = nil
        try? control?.close(); control = nil
        process = nil
        pending.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let (token, playback) = suppression {
            CapturePlaybackSuppression.end(token, using: playback, resuming: true)
        }
        suppression = nil
    }
}
#endif
