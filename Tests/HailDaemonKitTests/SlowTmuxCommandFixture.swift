#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// A test-owned executable and an acknowledged paste barrier; no tmux server is involved.
final class SlowTmuxCommandFixture: Sendable {
    let directory: URL
    let executable: String
    private let releaseFD: Int32
    static let binding = "$2@1758230001/%2:502"

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-submission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("tmux-fixture").path
        let fifo = directory.appendingPathComponent("release").path
        guard mkfifo(fifo, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        releaseFD = open(fifo, O_RDWR | O_NONBLOCK)
        guard releaseFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        try Self.script.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
    }

    deinit {
        release()
        close(releaseFD)
        try? FileManager.default.removeItem(at: directory)
    }

    func release() { _ = "continue\n".withCString { write(releaseFD, $0, strlen($0)) } }
    func mark(_ name: String) throws { try Data().write(to: directory.appendingPathComponent(name)) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
    func lines(_ name: String) -> [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }
    func wait(_ name: String) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !exists(name) {
            try #require(ContinuousClock.now < deadline, "fixture acknowledgement: \(name)")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static let script = #"""
    #!/bin/bash
    set -eu
    root="${0%/*}"
    echo launch >> "$root/launches"
    if [ "${1:-}" = '-L' ]; then shift 2; fi
    case "$1" in
      list-sessions)
        if [ -e "$root/rebound" ]; then echo '$2|1758230001|%2|999|codex'
        else echo '$2|1758230001|%2|502|codex'; fi ;;
      set-buffer)
        shift
        append=no
        if [ "$1" = '-a' ]; then append=yes; shift; fi
        buffer="$2"; shift 3
        if [ "$append" = yes ]; then printf '%s' "$1" >> "$root/$buffer"
        else printf '%s' "$1" > "$root/$buffer"; fi
        touch "$root/filled" ;;
      delete-buffer) rm -f "$root/$3"; touch "$root/deleted" ;;
      capture-pane) printf '> \n2,0,200\n' ;;
      paste-buffer|if-shell|send-keys)
        if [ "$1" = if-shell ]; then
          command="$6"
          if [ -e "$root/left-agent" ]; then
            if [[ "$command" = paste* ]]; then echo hail-paste-not-agent
            else echo hail-enter-not-agent; fi
            exit 0
          fi
          set -- $command
        fi
        if [ "$1" = paste-buffer ]; then
          echo paste >> "$root/writes"
          touch "$root/paste-started"
          if [ ! -e "$root/no-barrier" ]; then
            if ! read -r -t 15 line < "$root/release"; then touch "$root/timed-out"; exit 91; fi
          fi
          touch "$root/paste-finished"
        else
          echo enter >> "$root/writes"
          if [ -e "$root/enter-fails" ]; then exit 1; fi
          touch "$root/entered"
        fi ;;
    esac
    """#
}
#endif
