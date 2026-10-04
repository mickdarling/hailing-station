public import Foundation
import HailProtocol

/// Read-only queries over the device diagnostics log (#234) for `haild diagnostics`. Reading never creates,
/// follows a link to, or changes a file; each file is read only up to the writer's own cap plus headroom,
/// and a line that no longer decodes under the strict protocol rules is skipped.
public struct DiagnosticQuery: Sendable {
    /// A device token (`dev-` and 8 hex digits) or a device name, which is hashed to its token.
    public var device: String? {
        get { deviceToken }
        set { deviceToken = newValue.map { DiagnosticRecord.isDeviceToken($0) ? $0 : DiagnosticLog.deviceToken($0) } }
    }
    private var deviceToken: String?
    /// Host receive time, milliseconds since 1970.
    public var since: Int64?
    public var session: String?

    public init(device: String? = nil, since: Int64? = nil, session: String? = nil) {
        self.deviceToken = nil
        self.device = device
        self.since = since
        self.session = session
    }

    func matches(_ record: DiagnosticRecord) -> Bool {
        if let deviceToken, record.device != deviceToken { return false }
        if let since, record.received < since { return false }
        if let session, !record.session.uuidString.lowercased().hasPrefix(session.lowercased()) { return false }
        return true
    }
}

extension DiagnosticLog {
    /// Larger than any file the writer leaves behind; anything bigger is refused, not read.
    static let maxReadBytes = 8 * 1024 * 1024

    /// Matching records, oldest first, across the rotated file then the current one. A missing directory
    /// or file reads as empty.
    public nonisolated static func records(in directory: URL, matching query: DiagnosticQuery = .init())
        throws -> [DiagnosticRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let dir = try openDirectory(directory, create: false)
        defer { close(dir) }
        let decoder = FrameCoding.decoder()
        return try [rotatedName, fileName].flatMap { name in
            try read(name, in: dir, at: directory).split(separator: 0x0A).compactMap { line in
                (try? decoder.decode(DiagnosticRecord.self, from: Data(line))).flatMap { query.matches($0) ? $0 : nil }
            }
        }
    }

    private nonisolated static func read(_ name: String, in dir: Int32, at url: URL) throws -> Data {
        let path = url.appendingPathComponent(name).path
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            guard errno == ENOENT else { throw DiagnosticLogError.unsafe(path) }
            return Data()
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              Int(info.st_size) <= maxReadBytes else { throw DiagnosticLogError.unsafe(path) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maxReadBytes {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            guard count > 0 else { throw DiagnosticLogError.unsafe(path) }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data.prefix(maxReadBytes)
    }
}

extension DiagnosticRecord {
    /// One readable line: host receive time (UTC), short session id, device token, event and its fields. The
    /// device's own clock is shown as `device_ts` so skew is visible. Every free-standing value is a bare token
    /// only when it is one; anything else (a hand-edited or older log) is JSON-quoted, so a value can never add
    /// a field, a line, or text that reads as an instruction outside its quotes.
    public var line: String {
        let fields = event.fields.sorted { $0.key < $1.key }.map { field, value in
            switch value {
            case .token(let token): "\(field.rawValue)=\(Self.safe(token))"
            case .integer(let number): "\(field.rawValue)=\(number)"
            case .boolean(let flag): "\(field.rawValue)=\(flag)"
            }
        }
        let time = Self.timestamp(received)
        let session = String(session.uuidString.prefix(8))
        let device = Self.isDeviceToken(device) ? device : Self.safe(device)
        let deviceTime = "device_ts=\(Self.timestamp(event.timestamp))"
        return ([time, session, device, event.name.rawValue] + fields + [deviceTime]).joined(separator: " ")
    }

    static func isDeviceToken(_ value: String) -> Bool {
        value.count == 12 && value.hasPrefix("dev-") && value.dropFirst(4).allSatisfy("0123456789abcdef".contains)
    }

    /// The value bare when it is `[A-Za-z0-9._-]{1,32}`, otherwise as an escaped JSON string.
    static func safe(_ value: String) -> String {
        let bare = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if (1...32).contains(value.count), value.allSatisfy(bare.contains) { return value }
        // Printable ASCII stays; quotes, backslashes, controls and all non-ASCII become `\uXXXX` escapes; at most 64 units are shown.
        let escaped = value.utf16.prefix(64).map { unit -> String in
            guard (0x20...0x7E).contains(unit), unit != 0x22, unit != 0x5C else {
                return String(format: "\\u%04x", unit)
            }
            return String(UnicodeScalar(UInt8(unit)))
        }
        return "\"" + escaped.joined() + "\""
    }

    static func timestamp(_ milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}
