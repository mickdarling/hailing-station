/// Optional cooperative output authority (#167), separate from input delivery or observation grants.
/// A provider must invalidate the old gate before replacing or retiring its managed binding. Listing
/// snapshots and polling an external process are not equivalent to this contract.
public protocol ProviderReplyBindingLeasing: Adapter {
    func acquireReplyBindingLease(_ binding: ProviderSessionBinding) async throws -> ProviderReplyBindingLease
}

/// Exact host/provider/target/session/observation identity plus a revocable publication gate.
/// Acquisition is not authorization to enqueue later: the operation must execute inside this gate at
/// the final synchronous publication boundary, together with host policy and transport authority.
public struct ProviderReplyBindingLease: Sendable {
    public let binding: ProviderSessionBinding
    private let permit: ReplyPublicationPermit

    public init(binding: ProviderSessionBinding, permit: ReplyPublicationPermit) {
        self.binding = binding
        self.permit = permit
    }

    /// No actor hop or asynchronous work belongs inside the protected nonescaping operation.
    public func performIfCurrent<Result>(_ operation: () throws -> Result) rethrows -> Result? {
        try permit.performIfCurrent(operation)
    }
}
