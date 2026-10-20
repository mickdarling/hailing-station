import Darwin
import Foundation
import HailDaemonKit

enum CoachingCommandError: Error { case invalidConfiguration, localControlRequired, invalidControl }

/// Trusted explicit local choices only. Parsing does not query/select hardware, spawn, capture or play.
struct CoachingConfiguration {
    let executable: URL, config: URL, profile: URL, outputRoot: URL
    let listenerID: String
    let privateOutput: UInt32, roomMicrophone: UInt32
    let provider: RightyoCoachingProvider

    init(executable: URL, config: URL, profile: URL, outputRoot: URL, listenerID: String,
         privateOutput: UInt32, roomMicrophone: UInt32, provider: RightyoCoachingProvider = .mock) {
        self.executable = executable; self.config = config; self.profile = profile; self.outputRoot = outputRoot
        self.listenerID = listenerID; self.privateOutput = privateOutput; self.roomMicrophone = roomMicrophone
        self.provider = provider
    }

    static func parse(_ arguments: [String]) throws -> Self {
        let required: Set<String> = ["--rightyo", "--rightyo-config", "--listener-profile", "--listener",
                                     "--private-output", "--room-microphone", "--renderer-output-root"]
        let optional: Set<String> = ["--coaching-provider", "--coaching-max-requests", "--coaching-advice-catalog"]
        var fields: [String: String] = [:], rest = arguments[...], hostedTextConsent = false
        while let flag = rest.popFirst() {
            if flag == "--coaching-allow-hosted-text" {
                guard !hostedTextConsent else { throw CoachingCommandError.invalidConfiguration }
                hostedTextConsent = true; continue
            }
            guard required.union(optional).contains(flag), fields[flag] == nil, let value = rest.popFirst(),
                  !value.isEmpty, !value.contains("\0") else { throw CoachingCommandError.invalidConfiguration }
            fields[flag] = value
        }
        guard required.isSubset(of: Set(fields.keys)), let listener = fields["--listener"],
              validListener(listener), let output = device(fields["--private-output"]),
              let microphone = device(fields["--room-microphone"]), output != microphone else {
            throw CoachingCommandError.invalidConfiguration
        }
        return try Self(executable: path(fields["--rightyo"]), config: path(fields["--rightyo-config"]),
                        profile: path(fields["--listener-profile"]),
                        outputRoot: path(fields["--renderer-output-root"]), listenerID: listener,
                        privateOutput: output, roomMicrophone: microphone,
                        provider: provider(fields, consent: hostedTextConsent))
    }

    private static func provider(_ fields: [String: String], consent: Bool) throws -> RightyoCoachingProvider {
        let selected = fields["--coaching-provider"] ?? "mock"
        let budget = fields["--coaching-max-requests"], catalog = fields["--coaching-advice-catalog"]
        if selected == "mock", !consent, budget == nil, catalog == nil { return .mock }
        guard selected == "jev", consent, let budget,
              budget.utf8.allSatisfy({ (48...57).contains($0) }),
              let requests = Int(budget), (1...100).contains(requests), catalog != nil else {
            throw CoachingCommandError.invalidConfiguration
        }
        return .jev(hostedTextConsent: true, maxRequests: requests, adviceCatalog: try path(catalog))
    }

    /// Shared inert binder used by native composition and authored-only tests; it starts no runtime.
    func childConfiguration(profile: Data, provenance: RightyoAudioProvenance,
                            mockSuggestions: URL? = nil) -> CoachingChildTransport.Configuration {
        .init(executable: executable, config: config, profile: profile, listenerID: listenerID,
              provenance: provenance, mockSuggestions: mockSuggestions, provider: provider)
    }

    private static func validListener(_ value: String) -> Bool {
        CoachingChildCodec.identifier(value) && value.utf8.contains { $0 != 32 }
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
        guard Self.validListener(listenerID) else { throw CoachingCommandError.invalidConfiguration }
        let fd = open(profile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CoachingCommandError.invalidConfiguration }
        defer { close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG, details.st_uid == getuid(),
              details.st_mode & 0o077 == 0, details.st_size > 0, details.st_size <= 7_000,
              Self.hasNoExtendedACL(fd) else {
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

    /// Mode bits alone do not establish owner privacy on macOS. Query the same opened descriptor;
    /// any extended entry or inspection failure is refused, including conservative deny-only ACLs.
    static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        guard let access = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(access)) }
        var entry: acl_entry_t?
        return acl_get_entry(access, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }
}
