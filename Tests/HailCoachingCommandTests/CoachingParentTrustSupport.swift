import Darwin
import Foundation
import Security
@testable import haild

/// Shared by the parent-trust suites (#645): a private pin directory, a socketpair, and a pin of this
/// test process itself, which is built with the tests and signed ad hoc by the linker.
enum TrustSupport {
    static func selfPin() throws -> CoachingTrustedApp {
        var code: SecCode?, staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw CoachingParentRefusal.unverified
        }
        return try CoachingParentTrust.pin(for: staticCode)
    }

    struct Fixture {
        let root: URL
        var pin: URL { root.appendingPathComponent(CoachingTrustedApp.fileName) }
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("hailing-coaching-trust-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    struct SocketPair {
        let parent: Int32, child: Int32
        init() throws {
            var descriptors: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw CoachingParentRefusal.unverified
            }
            parent = descriptors[0]; child = descriptors[1]
        }
        func close() { Darwin.close(parent); Darwin.close(child) }
    }
}
