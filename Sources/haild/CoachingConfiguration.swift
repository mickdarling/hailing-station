import Darwin
import Foundation
import HailDaemonKit

enum CoachingCommandError: Error { case invalidConfiguration, localControlRequired, invalidControl }

/// Trusted explicit local choices only. Parsing does not query/select hardware, spawn, capture or play.
struct CoachingConfiguration {
    let executable: URL, config: URL, profile: URL, outputRoot: URL
    let listenerID: String
    let privateOutput: UInt32, roomMicrophone: UInt32

    static func parse(_ arguments: [String]) throws -> Self {
        let required: Set<String> = ["--rightyo", "--rightyo-config", "--listener-profile", "--listener",
                                     "--private-output", "--room-microphone", "--renderer-output-root"]
        var fields: [String: String] = [:], rest = arguments[...]
        while let flag = rest.popFirst() {
            guard required.contains(flag), fields[flag] == nil, let value = rest.popFirst(),
                  !value.isEmpty, !value.contains("\0") else { throw CoachingCommandError.invalidConfiguration }
            fields[flag] = value
        }
        guard Set(fields.keys) == required, let listener = fields["--listener"],
              CoachingChildCodec.identifier(listener), let output = device(fields["--private-output"]),
              let microphone = device(fields["--room-microphone"]), output != microphone else {
            throw CoachingCommandError.invalidConfiguration
        }
        return try Self(executable: path(fields["--rightyo"]), config: path(fields["--rightyo-config"]),
                        profile: path(fields["--listener-profile"]),
                        outputRoot: path(fields["--renderer-output-root"]), listenerID: listener,
                        privateOutput: output, roomMicrophone: microphone)
    }

    private static func device(_ value: String?) -> UInt32? {
        guard let value, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt32(value), number > 0 else { return nil }
        return number
    }
    private static func path(_ value: String?) throws -> URL {
        guard let value, value.hasPrefix("/") else { throw CoachingCommandError.invalidConfiguration }
        return URL(fileURLWithPath: value)
    }

    /// Private local profile, no symlink/FIFO/unbounded read. Errors never echo paths or profile contents.
    func loadProfile() throws -> Data {
        let fd = open(profile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CoachingCommandError.invalidConfiguration }
        defer { close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG, details.st_uid == getuid(),
              details.st_mode & 0o077 == 0, details.st_size > 0, details.st_size <= 7_000 else {
            throw CoachingCommandError.invalidConfiguration
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 7_001)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CoachingCommandError.invalidConfiguration }
            if count == 0 { break }
            guard data.count + count <= 7_000 else { throw CoachingCommandError.invalidConfiguration }
            data.append(contentsOf: buffer.prefix(count))
        }
        do { _ = try CoachingChildCodec.profile(data, listenerID: listenerID) } catch {
            throw CoachingCommandError.invalidConfiguration // Never propagate private profile parser diagnostics.
        }
        return data
    }
}
