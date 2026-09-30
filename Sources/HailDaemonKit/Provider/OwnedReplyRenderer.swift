#if os(macOS)
import Darwin
package import Foundation
import Synchronization

package enum OwnedReplyRendererError: Error, Equatable, CustomStringConvertible {
    case invalidOutputRoot, startupFailed, rendererUnavailable, nonzeroExit, cancelled, cleanupFailed, invalidAudio
    case ownershipLost
    case cleanupDeferred
    case unsupportedChildRuntime
    case publicationFailed

    package var description: String {
        switch self {
        case .invalidOutputRoot: "invalid private renderer output root"
        case .startupFailed: "renderer startup failed"
        case .rendererUnavailable: "speech renderer unavailable; owned output cleanup deferred"
        case .nonzeroExit: "speech renderer exited unsuccessfully; owned output cleanup deferred"
        case .cancelled: "speech renderer cancelled; owned output cleanup deferred"
        case .cleanupFailed: "owned renderer cleanup failed"
        case .invalidAudio: "invalid speech renderer output; owned output cleanup deferred"
        case .ownershipLost: "speech renderer child ownership lost"
        case .cleanupDeferred: "owned renderer cleanup deferred to job supervisor"
        case .unsupportedChildRuntime: "unsupported renderer child reaping runtime"
        case .publicationFailed: "speech reply publication failed; owned output cleanup deferred"
        }
    }
}

package enum OwnedReplyRendererCleanupDisposition: Sendable { case pending, completed, deferred, failed, ownershipLost }

struct ReplyRendererLifecycleHooks: Sendable {
    var startup: @Sendable () -> Void = {}
    var cleanup: @Sendable () -> Void = {}
    var retired: @Sendable (OwnedReplyRendererCleanupDisposition) -> Void = { _ in }
    var reaped: @Sendable () -> Void = {}
    var beforeEscalation: @Sendable () -> Void = {}
}

// Pure exact-PID cutoff state, separately testable without process-wide SIGCHLD changes or signals.
struct ReplyRendererChildIdentity: Sendable {
    var pid: pid_t?
    var status: Int32?
    var ownershipLost = false

    mutating func observe(result: pid_t, status: Int32, error: Int32) -> Bool {
        guard let pid else { return false }
        if result == pid {
            self.pid = nil; self.status = status
            return true
        }
        guard result == -1, error != EINTR else { return false }
        // ECHILD means the PID reservation is no longer ours. Any other terminal observation error
        // also fails closed: never signal a possibly reused numeric PID or claim safe file cleanup.
        self.pid = nil; ownershipLost = true
        return true
    }

    func signalIfOwned(_ operation: (pid_t) -> Void) {
        if let pid { operation(pid) }
    }

    static func supportsOwnership(handler: UInt, flags: Int32) -> Bool {
        handler == unsafeBitCast(SIG_DFL, to: UInt.self) && flags & SA_NOCLDWAIT == 0
    }

    static func requireOwnedRuntime() throws {
        var action = sigaction()
        guard sigaction(SIGCHLD, nil, &action) == 0,
              supportsOwnership(handler: unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self),
                                flags: action.sa_flags) else { throw OwnedReplyRendererError.unsupportedChildRuntime }
    }
}

private struct ReplyRendererState {
    var child: ReplyRendererChildIdentity
    var cancelled = false
    var retired = false
    var cleanupStarted = false
    var retirementReported = false
    var disposition = OwnedReplyRendererCleanupDisposition.pending
}

/// Trusted, non-daemonizing/non-escaping vbsay only, not a sandbox. Inherits the owning CLI's group;
/// signals only its own unreaped child. Kernel exit/reaping is not promised within a fixed deadline.
package final class OwnedReplyRenderer: Sendable {
    package let outputDirectory: URL
    private let lifetime: ReplyRendererLifetime

    package static func validateOutputRoot(_ root: URL) throws {
        try ReplyRendererChildIdentity.requireOwnedRuntime()
        let descriptor = try ReplyRendererFolder.openRoot(root)
        close(descriptor)
    }

    package convenience init(text: String, outputRoot: URL, environment: [String: String]) throws {
        try self.init(text: text, outputRoot: outputRoot, environment: environment,
                      hooks: ReplyRendererLifecycleHooks())
    }

    // Internal deterministic scheduling seam; the package CLI cannot supply a launcher or PID.
    init(text: String, outputRoot: URL, environment: [String: String], hooks: ReplyRendererLifecycleHooks) throws {
        try ReplyRendererChildIdentity.requireOwnedRuntime()
        try Task.checkCancellation()
        hooks.startup()
        lifetime = try ReplyRendererLifetime(text: text, outputRoot: outputRoot, environment: environment, hooks: hooks)
        outputDirectory = lifetime.folder.url
        if Task.isCancelled { lifetime.retire(cancel: true); throw OwnedReplyRendererError.cancelled }
    }

    deinit { lifetime.retire(cancel: true) }
    package var isRunning: Bool { lifetime.isRunning }
    package var cleanupComplete: Bool { lifetime.cleanupComplete }
    package var cleanupDisposition: OwnedReplyRendererCleanupDisposition { lifetime.cleanupDisposition }
    package func requireSuccessfulExit() async throws { try await lifetime.requireSuccessfulExit() }
    package func cancel() { lifetime.cancel() }
    package func retire(cancel: Bool) { lifetime.retire(cancel: cancel) }
    package func waitForCleanup() async throws { try await lifetime.waitForCleanup() }
    package func waitForCancellationSignals() async { await lifetime.waitForCancellationSignals() }
}

/// Separate from the facade: the exit source retains resource ownership, not the consumer itself.
private final class ReplyRendererLifetime: Sendable {
    let folder: ReplyRendererFolder
    private let state: Mutex<ReplyRendererState>
    private let processExit: any DispatchSourceProcess
    private let cleanupQueue = DispatchQueue(label: "hailing.reply-renderer.cleanup")
    private let exited = DispatchGroup()
    private let cleaned = DispatchGroup()
    private let signals = DispatchGroup()
    private let hooks: ReplyRendererLifecycleHooks

    init(text: String, outputRoot: URL, environment: [String: String], hooks: ReplyRendererLifecycleHooks) throws {
        let owned = try ReplyRendererFolder(root: outputRoot)
        let pid: pid_t
        do { pid = try Self.spawn(text: text, folder: owned.url, environment: environment) } catch {
            guard owned.remove() else { throw OwnedReplyRendererError.cleanupFailed }
            throw error
        }
        folder = owned
        self.hooks = hooks
        state = Mutex(ReplyRendererState(child: ReplyRendererChildIdentity(pid: pid)))
        processExit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        exited.enter(); cleaned.enter()
        // The source retains cleanup/reaping ownership even if the consumer returns on cancellation.
        processExit.setEventHandler { self.reap(observedExit: true) }
        processExit.activate()
        reap() // Close the registration race using nonblocking exact-child observation.
    }

    var isRunning: Bool { state.withLock { $0.child.pid != nil } }
    var cleanupComplete: Bool { state.withLock { $0.disposition == .completed } }
    var cleanupDisposition: OwnedReplyRendererCleanupDisposition { state.withLock { $0.disposition } }

    func requireSuccessfulExit() async throws {
        await withCheckedContinuation { done in exited.notify(queue: .global()) { done.resume() } }
        try state.withLock {
            if $0.child.ownershipLost { throw OwnedReplyRendererError.ownershipLost }
            if $0.cancelled { throw OwnedReplyRendererError.cancelled }
            guard let status = $0.child.status else { throw OwnedReplyRendererError.nonzeroExit }
            if status == 127 << 8 { throw OwnedReplyRendererError.rendererUnavailable }
            guard status == 0 else { throw OwnedReplyRendererError.nonzeroExit }
        }
    }

    /// Consumer retirement follows stable-file/finalization reads. Abnormal retirement reports
    /// deferred cleanup immediately, but the source retains exact-child responsibility while alive.
    func retire(cancel: Bool) {
        state.withLock { $0.retired = true }
        if cancel { self.cancel() }
        reportDeferredRetirement()
        cleanupIfReady()
    }

    func cancel() {
        let signal = state.withLock { current -> Bool in
            guard !current.cancelled else { return false }
            current.cancelled = true
            current.child.signalIfOwned { _ = kill($0, SIGTERM) }
            if current.child.pid != nil { signals.enter() }
            return current.child.pid != nil
        }
        if signal {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
                self.hooks.beforeEscalation()
                // Reaping and signaling share the same lock: no reused PID can be signaled.
                self.state.withLock { $0.child.signalIfOwned { _ = kill($0, SIGKILL) } }
                self.signals.leave()
            }
        }
    }

    func waitForCancellationSignals() async {
        await withCheckedContinuation { done in signals.notify(queue: .global()) { done.resume() } }
    }

    private func reportDeferredRetirement() {
        let disposition = state.withLock { current -> OwnedReplyRendererCleanupDisposition in
            guard current.retired else { return .pending }
            if current.child.ownershipLost { return .ownershipLost }
            if current.cancelled || (current.child.status != nil && current.child.status != 0) { return .deferred }
            return .pending
        }
        if disposition != .pending { reportRetirement(disposition) }
    }

    private func reportRetirement(_ disposition: OwnedReplyRendererCleanupDisposition) {
        let first = state.withLock { current -> Bool in
            guard !current.retirementReported else { return false }
            current.retirementReported = true; current.disposition = disposition
            return true
        }
        if first { cleaned.leave(); hooks.retired(disposition) }
    }

    func waitForCleanup() async throws {
        await withCheckedContinuation { done in cleaned.notify(queue: .global()) { done.resume() } }
        switch cleanupDisposition {
        case .completed: return
        case .deferred: throw OwnedReplyRendererError.cleanupDeferred
        case .ownershipLost: throw OwnedReplyRendererError.ownershipLost
        case .pending, .failed: throw OwnedReplyRendererError.cleanupFailed
        }
    }

    private func reap(observedExit: Bool = false) {
        let reaped = state.withLock { current -> Bool in
            guard let pid = current.child.pid else { return false }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            return current.child.observe(result: result, status: status, error: errno)
        }
        if reaped {
            exited.leave()
            hooks.reaped()
            cleanupIfReady()
        } else if !isRunning {
            cleanupIfReady()
        }
        // An exit event may precede waitpid readiness or be interrupted; never block the callback.
        if isRunning, observedExit {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.01) {
                self.reap(observedExit: true)
            }
        }
    }

    private func cleanupIfReady() {
        let ready = state.withLock { current -> Bool in
            guard current.retired, current.child.pid == nil, !current.cleanupStarted else { return false }
            current.cleanupStarted = true
            return true
        }
        guard ready else { return }
        cleanupQueue.async {
            let disposition = self.state.withLock { current -> OwnedReplyRendererCleanupDisposition in
                if current.child.ownershipLost { return .ownershipLost }
                if current.cancelled || current.child.status != 0 { return .deferred }
                return .pending
            }
            let completed: OwnedReplyRendererCleanupDisposition
            if disposition == .pending {
                completed = self.folder.remove(checkpoint: self.hooks.cleanup) ? .completed : .failed
            } else { self.folder.abandon(); completed = disposition }
            self.reportRetirement(completed)
            self.processExit.setEventHandler {}
            self.processExit.cancel()
        }
    }
}

extension ReplyRendererLifetime {
    private static func spawn(text: String, folder: URL, environment input: [String: String]) throws -> pid_t {
        var environment = input
        environment["VBSAY_NOPLAY"] = "1"; environment["VBSAY_OUT"] = folder.path
        environment["VBSAY_CHUNK"] = environment["VBSAY_CHUNK"] ?? "160"
        let values = ["/usr/bin/env", "vbsay", text] + environment.map { "\($0.key)=\($0.value)" }
        guard !values.contains(where: { $0.contains("\0") }) else {
            throw OwnedReplyRendererError.startupFailed
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw OwnedReplyRendererError.startupFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw OwnedReplyRendererError.startupFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        // Deliberately no SETPGROUP or SETSID: the outer trusted job alone owns group creation/signals.
        let setup = [posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                     posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0),
                     posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
                     posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))]
        guard setup.allSatisfy({ $0 == 0 }) else { throw OwnedReplyRendererError.startupFailed }
        let argumentStrings = ["/usr/bin/env", "vbsay", text]
        var arguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) } + [nil]
        var entries = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { arguments.forEach { free($0) }; entries.forEach { free($0) } }
        guard arguments.dropLast().allSatisfy({ $0 != nil }), entries.dropLast().allSatisfy({ $0 != nil }) else {
            throw OwnedReplyRendererError.startupFailed
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/usr/bin/env", &actions, &attributes, &arguments, &entries) == 0 else {
            throw OwnedReplyRendererError.startupFailed
        }
        return pid
    }
}

private struct ReplyRendererFolder: Sendable {
    let root: URL
    let url: URL
    let rootIdentity: (device: dev_t, inode: ino_t)
    let identity: (device: dev_t, inode: ino_t)
    let rootDescriptor: Int32

    static func openRoot(_ root: URL) throws -> Int32 {
        do {
            guard root.isFileURL, let descriptor = try PolicyFile(directory: root).openDirectory() else {
                throw OwnedReplyRendererError.invalidOutputRoot
            }
            var information = stat()
            guard fstat(descriptor, &information) == 0, information.st_mode & 0o777 == 0o700,
                  hasNoExtendedACL(descriptor) else {
                close(descriptor)
                throw OwnedReplyRendererError.invalidOutputRoot
            }
            return descriptor
        } catch { throw OwnedReplyRendererError.invalidOutputRoot }
    }

    private static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        guard let access = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(access)) }
        var entry: acl_entry_t?
        return acl_get_entry(access, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }

    init(root: URL) throws {
        let descriptor = try Self.openRoot(root)
        var keep = false
        defer { if !keep { close(descriptor) } }
        var information = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &information) == 0, fcntl(descriptor, F_GETPATH, &path) == 0 else {
            throw OwnedReplyRendererError.startupFailed
        }
        let pathBytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let rootPath = String(bytes: pathBytes, encoding: .utf8) else {
            throw OwnedReplyRendererError.startupFailed
        }
        self.root = URL(fileURLWithPath: rootPath, isDirectory: true)
        rootIdentity = (information.st_dev, information.st_ino)
        let name = "hailing-vbsay-\(UUID().uuidString)"
        url = self.root.appendingPathComponent(name, isDirectory: true)
        guard mkdirat(descriptor, name, 0o700) == 0 else { throw OwnedReplyRendererError.startupFailed }
        var child = stat()
        guard fstatat(descriptor, name, &child, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw OwnedReplyRendererError.cleanupFailed // No identity proof: never remove by an unchecked name.
        }
        identity = (child.st_dev, child.st_ino)
        rootDescriptor = descriptor; keep = true
    }

    func remove(checkpoint: @Sendable () -> Void = {}) -> Bool {
        defer { close(rootDescriptor) }
        // Pathnames are preflight only; recursive deletion is anchored to the owned directory FD.
        guard let parent = try? PolicyFile.info(root), parent.st_dev == rootIdentity.device,
              parent.st_ino == rootIdentity.inode, let child = try? PolicyFile.info(url),
              child.st_dev == identity.device, child.st_ino == identity.inode,
              child.st_mode & S_IFMT == S_IFDIR else { return false }
        checkpoint()
        guard let currentRoot = try? PolicyFile.info(root), currentRoot.st_dev == rootIdentity.device,
              currentRoot.st_ino == rootIdentity.inode else { return false }
        let descriptor = openat(rootDescriptor, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == identity.device,
              opened.st_ino == identity.inode, opened.st_uid == getuid(), opened.st_mode & 0o777 == 0o700,
              Self.removeContents(descriptor, depth: 0) else { return false }
        var current = stat()
        guard fstatat(rootDescriptor, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == identity.device, current.st_ino == identity.inode else { return false }
        // POSIX has no inode-conditional rmdir. The trusted root/renderer must not rebind this empty
        // name concurrently; this is not a hostile same-UID sandbox or an unconditional deletion claim.
        return unlinkat(rootDescriptor, url.lastPathComponent, AT_REMOVEDIR) == 0
    }
    func abandon() { close(rootDescriptor) } // Unknown child ownership: keep files for explicit local recovery.
}

extension ReplyRendererFolder {
    private static func removeContents(_ descriptor: Int32, depth: Int) -> Bool {
        guard depth < 8, let names = entryNames(descriptor) else { return false }
        for name in names {
            var information = stat()
            guard fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            if information.st_mode & S_IFMT == S_IFDIR {
                guard removeDirectory(name, parent: descriptor, identity: information, depth: depth + 1) else {
                    return false
                }
            } else {
                guard unlinkat(descriptor, name, 0) == 0 else { return false }
            }
        }
        return true
    }

    private static func entryNames(_ descriptor: Int32) -> [String]? {
        let copy = dup(descriptor)
        guard copy >= 0 else { return nil }
        guard let directory = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? names : nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
            guard names.count <= 1_024 else { return nil }
        }
    }

    private static func removeDirectory(_ name: String, parent: Int32, identity: stat, depth: Int) -> Bool {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_dev == identity.st_dev,
              information.st_ino == identity.st_ino, removeContents(descriptor, depth: depth),
              fstatat(parent, name, &information, AT_SYMLINK_NOFOLLOW) == 0,
              information.st_dev == identity.st_dev, information.st_ino == identity.st_ino else { return false }
        return unlinkat(parent, name, AT_REMOVEDIR) == 0
    }
}
// Keep this exact-child/owned-directory boundary in one file within the four-production-file prerequisite.
// swiftlint:disable:next file_length
#endif
