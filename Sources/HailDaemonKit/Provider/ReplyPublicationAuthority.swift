import Synchronization

/// Object identity is a revision: retained old permits cannot wrap around or regain validity.
private final class ReplyPublicationRevision: Sendable {}

/// A cooperative authority gate, local to its owner; not a policy, recipient or binding grant by itself.
/// Revocation and synchronous publication operations share one lock and one explicit ordering boundary.
public final class ReplyPublicationAuthority: Sendable {
    private let revision = Mutex(ReplyPublicationRevision())

    public init() {}

    public func issuePermit() -> ReplyPublicationPermit {
        revision.withLock { ReplyPublicationPermit(authority: self, revision: $0) }
    }

    /// Linearizes revocation. An operation already running finishes first; old permits then stay invalid.
    /// Caller operations must be short, synchronous and non-reentrant: no network wait or gate re-entry.
    public func invalidate() {
        revision.withLock { $0 = ReplyPublicationRevision() }
    }

    fileprivate func performIfCurrent<Result>(
        _ expected: ReplyPublicationRevision, operation: () throws -> Result
    ) rethrows -> Result? {
        try revision.withLock { current in
            guard current === expected else { return nil }
            return try operation()
        }
    }
}

/// Immutable, opaque evidence for one gate revision. No cached Boolean escapes the synchronized check.
public struct ReplyPublicationPermit: Sendable {
    private let authority: ReplyPublicationAuthority
    private let revision: ReplyPublicationRevision

    fileprivate init(authority: ReplyPublicationAuthority, revision: ReplyPublicationRevision) {
        self.authority = authority
        self.revision = revision
    }

    /// Runs a nonescaping operation only while its exact revision is current; nil means it did not run.
    /// Do not await, wait for network completion, or re-enter/invalidate this same gate from the operation.
    /// Composing distinct gates requires a consistent lock order across all users.
    public func performIfCurrent<Result>(_ operation: () throws -> Result) rethrows -> Result? {
        try authority.performIfCurrent(revision, operation: operation)
    }
}
