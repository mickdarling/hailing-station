extension HailHost {
    public var currentLockdown: LockdownState { lockdown }

    /// Lockdown wins over policy, sanitization, and target errors so every caller reports the safety state.
    func requireSendPreflight() throws {
        if lockdown.isOn { throw HostError.denied(.lockdown) }
        try requirePolicy()
    }

    /// Engagement can come from either end or an automatic trigger. A blank diagnostic reason is replaced
    /// with a safe canonical reason, so missing metadata can never prevent the fail-closed transition.
    /// A real transition revokes outstanding confirmation authority before the next delivery check. A line
    /// already handed to an adapter may still complete; #43 tracks the adapter-side pre-Enter check.
    @discardableResult
    public func engageLockdown(reason: String) -> LockdownTransition? {
        let transition = lockdown.engage(reason: reason)
        if transition != nil { revokeAuthority() }
        return transition
    }

    // This slice intentionally exposes no lift operation. #43 must add lifting at the trusted local Mac
    // integration boundary; a caller-asserted enum or other public HailHost method is not physical presence.
}
