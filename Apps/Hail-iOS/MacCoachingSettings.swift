#if os(macOS)
import Darwin
import Foundation
import HailCore

/// Owner-local setup only; profile parsing and all audio/provider qualification stay in the shared runtime.
struct MacCoachingSettings: Decodable {
    let rightyo: String
    let config: String
    let profile: String
    let rendererOutputRoot: String
    let listener: String
    let adviceCatalog: String?
    let maxRequests: Int?
    let hostedTextConsent: Bool
    let speechEnvironment: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case rightyo, config, profile, rendererOutputRoot, listener, adviceCatalog, maxRequests
        case speechEnvironment, hostedTextConsent
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rightyo = try values.decode(String.self, forKey: .rightyo)
        config = try values.decode(String.self, forKey: .config)
        profile = try values.decode(String.self, forKey: .profile)
        rendererOutputRoot = try values.decode(String.self, forKey: .rendererOutputRoot)
        listener = try values.decode(String.self, forKey: .listener)
        adviceCatalog = try values.decodeIfPresent(String.self, forKey: .adviceCatalog)
        maxRequests = try values.decodeIfPresent(Int.self, forKey: .maxRequests)
        speechEnvironment = try values.decodeIfPresent([String: String].self, forKey: .speechEnvironment)
        hostedTextConsent = try values.decodeIfPresent(Bool.self, forKey: .hostedTextConsent) ?? false
    }

    static var rendererEnvironment: [String: String] {
        let allowed: Set<String> = ["PATH", "VBSAY_PROFILE", "VBSAY_NOFALLBACK", "VOICEBOX_URL", "VBSTREAM_URL"]
        let configured = (try? load().speechEnvironment) ?? [:]
        let filtered = configured.filter { allowed.contains($0.key) }
        return ProcessInfo.processInfo.environment.merging(filtered) { _, new in new }
    }

    static func load() throws -> Self {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hail/coaching-local", isDirectory: true)
        let descriptor = open(root.appendingPathComponent("mac-app.json").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(descriptor) }
        var details = stat()
        guard fstat(descriptor, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
              details.st_uid == getuid(), details.st_mode & 0o077 == 0,
              details.st_size > 0, details.st_size <= 8_192, hasNoExtendedACL(descriptor) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_193)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= 8_192 else { throw CocoaError(.fileReadCorruptFile) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        guard let access = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(access)) }
        var entry: acl_entry_t?
        return acl_get_entry(access, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }

    func arguments(microphone: UInt32, output: UInt32) throws -> [String] {
        var arguments = ["--rightyo", rightyo, "--rightyo-config", config, "--listener-profile", profile,
            "--renderer-output-root", rendererOutputRoot, "--listener", listener,
            "--room-microphone", String(microphone), "--private-output", String(output)]
        arguments += try CoachingHostedProviderArguments.make(catalog: adviceCatalog, maxRequests: maxRequests,
                                                               consent: hostedTextConsent)
        return arguments
    }
}
#endif
