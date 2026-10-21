#if os(macOS)
import AppKit
import Darwin
import Foundation
import HailCore
import Observation

/// Runs one `haild coaching --parent-control` child per Start (#645). The child owns the coaching foundation
/// (capture, the RightyO child, speech and the private output). Its stdin is one end of a socketpair this app
/// creates, so haild can check this app's code signature from the socket's peer token before reading any setup.
/// The app sends only control words and reads only content-free status lines. Any other bytes are dropped unread,
/// so transcript or advice text never reaches the app, and nothing here is logged. If the app quits, the socket
/// closes and haild retires coaching.
@MainActor @Observable
final class MacCoachingController {
    static let shared = MacCoachingController()

    /// Seam for Mick's pending focus decision (#645): today losing the app's focus stops the run, the rule the
    /// foundation also applies in-process. The first microphone prompt for the child may itself take focus.
    static let stopsWhenAppResigns = true

    private(set) var model = PrivateCoachingCardModel()
    var state: PrivateCoachingCardState { model.state }

    @ObservationIgnored private let exclusion: PrivateListeningExclusion
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var control: Int32 = -1
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var suppression: (token: UUID, playback: ReplyPlaybackController)?

    init(exclusion: PrivateListeningExclusion = .shared) { self.exclusion = exclusion }

    /// Awareness and any consent (inside `arguments`) were confirmed in the card just before this call.
    func start(executable: String, arguments: [String], playback: ReplyPlaybackController) {
        guard state.canStart, process == nil, exclusion.claimCoaching() else { return }
        model.startRequested()
        let token = UUID()
        suppression = (token, playback)
        CapturePlaybackSuppression.begin(token, using: playback) // Replies wait while coaching holds audio.
        var ends: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { finish(); return }
        var one: Int32 = 1
        _ = setsockopt(ends[0], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardInput = FileHandle(fileDescriptor: ends[1], closeOnDealloc: false)
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch {
            Darwin.close(ends[0]); Darwin.close(ends[1]); finish(); return
        }
        Darwin.close(ends[1]) // Only the child holds its end, so its exit is our EOF.
        process = child
        control = ends[0]
        read(from: ends[0])
        send("enable aware")
        watchStatusAndFocus()
    }

    func stop() {
        guard state.holdsAudio else { return }
        model.stopRequested()
        send("off")
        send("quit")
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            // Last resorts; haild's own retirement normally ends it within a second.
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let process = self?.process, process.isRunning else { return }
            process.terminate()
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let process = self?.process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// One ordered stream from a background reader to one main-actor consumer, so the last status line is always
    /// handled before EOF ends the run.
    private func read(from socket: Int32) {
        let duplicate = dup(socket)
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(duplicate, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                continuation.yield(Data(buffer.prefix(count)))
            }
            Darwin.close(duplicate)
            continuation.finish()
        }
        reader = Task { @MainActor [weak self] in
            var pending = Data()
            for await chunk in chunks { self?.receive(chunk, pending: &pending) }
            self?.exited()
        }
    }

    private func watchStatusAndFocus() {
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.state.holdsAudio else { return }
                self.send("status") // The child reports a route end only in reply to a control line.
            }
        }
        var names = [NSApplication.willTerminateNotification]
        if Self.stopsWhenAppResigns { names.append(NSApplication.didResignActiveNotification) }
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.stop() }
            })
        }
    }

    private func send(_ word: String) {
        guard control >= 0 else { return }
        let bytes = Data((word + "\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(control, $0.baseAddress, $0.count) }
        if written != bytes.count { Darwin.shutdown(control, SHUT_WR) } // The child is gone; EOF ends the run.
    }

    private func receive(_ data: Data, pending: inout Data) {
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
        reader = nil
        if control >= 0 { Darwin.close(control); control = -1 }
        process = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let (token, playback) = suppression {
            CapturePlaybackSuppression.end(token, using: playback, resuming: true)
        }
        suppression = nil
        exclusion.releaseCoaching()
    }
}
#endif
