#if os(macOS)
import Foundation
import Synchronization

/// Saves the owner's note by its destination's handler (#552). Each kind of destination is code here, and the
/// owner's destinations file only picks one and its target. Returns an outcome token for logs: "saved" on success.
struct VoiceNoteRunner: Sendable {
    var markdown = MarkdownNoteWriter()
    var shortcuts = ShortcutRunner()

    func run(_ target: VoiceDestinations.Destination, text: String) async -> String {
        switch target {
        case .markdown(let path): markdown.append(text, to: path)
        case .shortcut(let name): await shortcuts.run(name, text: text)
        }
    }
}

/// Appends a note to a Markdown file (#552) as one list item, `- yyyy-MM-dd HH:mm <words>`, with line breaks in the
/// words made spaces. A file that does not end in a newline gets one first. An absent file is created `0600` (its
/// directory must exist); the last component is never followed as a symlink, and only a regular file is written.
struct MarkdownNoteWriter: Sendable {
    var now: @Sendable () -> Date = { Date() }

    func append(_ text: String, to path: String) -> String {
        let descriptor = open(path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return "open_failed" }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return "not_a_file" }
        var last: UInt8 = 0
        let separate = info.st_size > 0 && pread(descriptor, &last, 1, info.st_size - 1) == 1
            && last != UInt8(ascii: "\n")
        let words = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let bytes = Array(((separate ? "\n" : "") + "- \(Self.stamp(now())) \(words)\n").utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return "write_failed" }
            written += count
        }
        return "saved"
    }

    /// Local time, to the minute, in a fixed format whatever the host's locale.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        (formatter.locale, formatter.dateFormat) = (Locale(identifier: "en_US_POSIX"), "yyyy-MM-dd HH:mm")
        return formatter.string(from: date)
    }
}

/// Runs one allowlisted Shortcut with a note as its input (#552): `shortcuts run <name> --input-path <file>`, no
/// shell, the words only in a private temporary file that is removed afterwards. Returns an outcome token for logs.
struct ShortcutRunner: Sendable {
    var executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    var timeout: Duration = .seconds(30)

    func run(_ shortcut: String, text: String) async -> String {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("hail-note-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: input.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return "input_failed" }
        defer { try? FileManager.default.removeItem(at: input) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["run", shortcut, "--input-path", input.path]
        // As for the RightyO child: a fixed PATH with HOME and TMPDIR, never the rest of haild's environment.
        process.environment = RightyoChildProcess.environment()
        (process.standardInput, process.standardOutput, process.standardError) = (nil, nil, nil)
        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exited.continuation.yield($0.terminationStatus) }
        do { try process.run() } catch { return "launch_failed" }
        let timedOut = Mutex(false)
        // SIGTERM at the timeout, then SIGKILL if it is ignored, so the wait below always ends.
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { timer.cancel() }
        var statuses = exited.stream.makeAsyncIterator()
        guard let status = await statuses.next() else {
            // The caller was cancelled: the Shortcut is stopped, never left running on a removed input.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return "cancelled"
        }
        if timedOut.withLock({ $0 }) { return "timeout" }
        if process.terminationReason == .uncaughtSignal { return "signal_\(status)" }
        return status == 0 ? "saved" : "exit_\(status)"
    }
}
#endif
