import Darwin
public import Foundation

/// Local paths for `haild coaching` (#645), read from a small JSON file the owner writes. The card never shows or
/// logs these paths. Parsing checks shape only; haild re-validates every file before it starts anything.
///
/// ```json
/// { "haild": "/abs/haild", "rightyo": "/abs/rightyo", "rightyoConfig": "/abs/config",
///   "listenerProfile": "/abs/profile", "listener": "owner", "rendererOutputRoot": "/abs/dir",
///   "speechServices": "local", "hosted": { "maxRequests": 20, "adviceCatalog": "/abs/catalog" } }
/// ```
/// `hosted` is optional. Without it only the local mock provider is offered. `speechServices` is required: the
/// owner declares whether the RightyO config's recognition or the renderer's synthesis is hosted, and "hosted"
/// adds its own consent step. haild does not check this declaration.
public struct PrivateCoachingSetup: Sendable, Equatable, Decodable {
    public struct Hosted: Sendable, Equatable, Decodable {
        public let maxRequests: Int
        public let adviceCatalog: String
    }

    public enum Provider: Sendable, Equatable { case local, hosted }

    public enum SpeechServices: String, Sendable, Equatable, Decodable { case local, hosted }

    public enum SetupError: Error, Equatable {
        case invalid, untrustedFile, hostedNotConfigured, hostedConsentRequired, hostedSpeechConsentRequired
    }

    public let haild: String
    public let rightyo: String
    public let rightyoConfig: String
    public let listenerProfile: String
    public let listener: String
    public let rendererOutputRoot: String
    public let speechServices: SpeechServices
    public let hosted: Hosted?

    /// Reads the owner's setup file, then checks that `haild` is a file only this user (or root) can change.
    /// A symlinked, shared-writable or oversized setup file is refused, so another account cannot point the app
    /// at a different executable that would run under the app's microphone permission.
    public static func load(from url: URL) throws -> Self {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SetupError.untrustedFile }
        defer { close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG, details.st_uid == getuid(),
              details.st_mode & 0o022 == 0, (1...4_096).contains(details.st_size) else {
            throw SetupError.untrustedFile
        }
        var buffer = [UInt8](repeating: 0, count: 4_097)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0, count <= 4_096 else { throw SetupError.untrustedFile }
        let setup = try parse(Data(buffer.prefix(count)))
        guard trustedExecutable(setup.haild) else { throw SetupError.untrustedFile }
        return setup
    }

    /// The final component and every directory above it: not a symlink, owned by this user or root, and not
    /// writable by group or others. The executable must also be a regular, executable file.
    static func trustedExecutable(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: path).standardizedFileURL.path
        guard current == path else { return false }
        var details = stat()
        guard lstat(current, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
              details.st_mode & 0o100 != 0, owned(details) else { return false }
        while current != "/" {
            current = (current as NSString).deletingLastPathComponent
            guard lstat(current, &details) == 0, details.st_mode & S_IFMT == S_IFDIR, owned(details) else {
                return false
            }
        }
        return true
    }

    private static func owned(_ details: stat) -> Bool {
        (details.st_uid == getuid() || details.st_uid == 0) && details.st_mode & 0o022 == 0
    }

    /// The file must be small, decode exactly, and carry only absolute paths and a listener ID haild accepts.
    public static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4_096,
              let setup = try? JSONDecoder().decode(Self.self, from: data) else { throw SetupError.invalid }
        let paths = [setup.haild, setup.rightyo, setup.rightyoConfig, setup.listenerProfile,
                     setup.rendererOutputRoot] + (setup.hosted.map { [$0.adviceCatalog] } ?? [])
        guard paths.allSatisfy(absolutePath), CoachingWireAdvice.identifier(setup.listener) else {
            throw SetupError.invalid
        }
        if let hosted = setup.hosted, !(1...100).contains(hosted.maxRequests) { throw SetupError.invalid }
        return setup
    }

    public var offersHosted: Bool { hosted != nil }

    /// Arguments after the haild executable. The hosted flags appear only with the hosted provider AND its consent.
    /// Device numbers are fresh HAL IDs from the inventory; haild re-reads their OS evidence before binding.
    public func arguments(privateOutput: UInt32, roomMicrophone: UInt32, provider: Provider,
                          hostedConsentConfirmed: Bool, hostedSpeechConsentConfirmed: Bool) throws -> [String] {
        guard privateOutput > 0, roomMicrophone > 0, privateOutput != roomMicrophone else {
            throw SetupError.invalid
        }
        guard speechServices == .local || hostedSpeechConsentConfirmed else {
            throw SetupError.hostedSpeechConsentRequired
        }
        var arguments = ["coaching", "--parent-control",
                         "--rightyo", rightyo, "--rightyo-config", rightyoConfig,
                         "--listener-profile", listenerProfile, "--listener", listener,
                         "--private-output", String(privateOutput), "--room-microphone", String(roomMicrophone),
                         "--renderer-output-root", rendererOutputRoot]
        guard provider == .hosted else { return arguments }
        guard let hosted else { throw SetupError.hostedNotConfigured }
        guard hostedConsentConfirmed else { throw SetupError.hostedConsentRequired }
        arguments += ["--coaching-provider", "jev", "--coaching-allow-hosted-text",
                      "--coaching-max-requests", String(hosted.maxRequests),
                      "--coaching-advice-catalog", hosted.adviceCatalog]
        return arguments
    }

    private static func absolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.count <= 1_024 && !value.contains("\0") && !value.contains("\n")
    }
}
