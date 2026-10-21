import Foundation
import HailProtocol

// The phone frame and local dispatch ingress paths share one handoff-and-commit boundary here.
// swiftlint:disable file_length

/// Both ingress paths share one lease, permit, handoff and commit; they differ only in how they report it.
enum HostDeliveryOutcome: Sendable, Equatable {
    /// Handed off; `request` is this connection's committed reply owner, or nil for legacy generic input that
    /// carried no host-minted ambient reference (#230).
    case delivered(request: UUID?)
    case confirmationRequired
    /// The connection selected another target while this input was suspended; nothing was handed off.
    case selectionChanged
    /// The target may have received the text, but no reply ownership survived the handoff.
    case unowned(String)
    case refused(ErrorCode, String)
}

/// One input's reply owner. A contextual adapter receives `context` with the text. A host-minted ambient reference on
/// a legacy adapter (#230) is recorded host-side only: the text goes the legacy way, pinned to the recorded binding.
struct HostReplyOwnership {
    let context: ProviderTurnContext
    let contextual: Bool
}

extension HostSession {
    /// The opaque reply reference `WebSocketListener.dispatchAmbient` minted for one ambient handoff and wrote into
    /// that prompt's reply block (#230), bound only for the duration of that dispatch. On a legacy adapter only, it
    /// names the request record this session mints for its own connection, selection generation and exact target
    /// binding; a contextual adapter ignores it and keeps its own out-of-band context id. It is a routing
    /// handle, not origin evidence, and nothing a client or the local socket sends can set it.
    @TaskLocal static var ambientReplyReference: UUID?

    /// True only inside `WebSocketListener.dispatchAmbient` (#370): this handoff is the streaming device's own
    /// ambient input, so a delivered handoff makes this connection its target's last input device. The local
    /// socket's `dispatch` kind and `haild rightyo --reply-to` never set it.
    @TaskLocal static var ambientInputDispatch = false

    func route(_ admitted: consuming AdmittedFrame, version: Int) async -> HostSessionResult {
        switch consume admitted {
        case .input(let input):
            return await deliver(input, version: version)
        case .control(let control):
            return await route(control, version: version)
        case .nonFinalText:
            return failure(.malformed, "only final text can be delivered", close: false, version: version)
        case .untargetedText:
            return failure(.notAllowed, "select the destination before speaking", close: false, version: version)
        case .lockedDownPaste:
            return failure(.lockdown, "target action was refused", close: false, version: version)
        case .refusedPaste(let reason):
            return failure(pasteRefusal(.malformed), reason, close: false, version: version)
        case .audio(let audio, let target):
            return await ambient(audio, target: target, version: version)
        case .unsupported:
            return failure(.unauthorized, "terminal action is not authorized", close: false, version: version)
        }
    }

    /// Ambient segments never reach `HailHost.send`; the gate hands admitted bytes to its injected sink. A stream
    /// that took listening over from another device (#366) is told so, if this device advertised that it can hear it.
    private func ambient(_ audio: AudioPayload, target: String?, version: Int) async -> HostSessionResult {
        guard let gate = authorizer.ambientAudio else {
            return failure(.unauthorized, "terminal action is not authorized", close: false, version: version)
        }
        switch await gate.admission(
            audio, frameTarget: target, selectedTarget: selectedTarget, connection: connectionID,
            device: peerDeviceKind
        ) {
        case .admitted:
            return HostSessionResult(frames: [])
        case .tookOver(let from):
            guard peerCapabilities.contains(AmbientTakeOver.capability) else { return HostSessionResult(frames: []) }
            return HostSessionResult(frames: [response(.ambientMovedHere(from: from), version: version)])
        case .refused(let code, let message):
            return failure(code, message, close: false, version: version)
        }
    }

    private func deliver(_ input: consuming AuthorizedInput, version: Int) async -> HostSessionResult {
        // A request that carried a paste (#608) and was refused as not allowed or malformed is answered with
        // `paste_refused` to a device that takes request refusals, so it ends that request and keeps the connection;
        // the message is the plain reason. Lockdown, rate limits and unknown targets keep their own codes, as for
        // spoken text. Spoken text alone, and any device without the capability, is answered as before.
        let carriesPaste = input.carriesPaste, takesRefusals = peerCapabilities.contains(RequestRefusals.capability)
        let refusal: (ErrorCode) -> ErrorCode = { code in
            Self.refusalCode(code, carriesPaste: carriesPaste, takesRequestRefusals: takesRefusals)
        }
        // A phone's own final text frame (tap-to-talk) is input from this device (#370).
        switch await deliver(input, recordsLastInput: true) {
        case .delivered:
            return HostSessionResult(frames: [])
        case .confirmationRequired:
            let message = "target requires confirmation at the Mac"
            return failure(refusal(.notAllowed), message, close: false, version: version)
        case .selectionChanged:
            return failure(refusal(.notAllowed), "request destination changed", close: false, version: version)
        case .unowned(let message):
            // Handed off, but with no reply owner: not a refusal of the request, answered as for spoken text.
            return failure(.notAllowed, message, close: false, version: version)
        case .refused(let code, let message):
            return failure(refusal(code), message, close: false, version: version)
        }
    }

    /// Lease, permit, capacity, lifetime and generation checks, then `HailHost.send` with its sanitizer,
    /// shape and policy gates; only a successful complete handoff commits the request record. The input
    /// type is the authorization proof: nothing reaches the host that the session's authorizer did not
    /// allow, and the proof is consumed here, so one decision admits exactly one handoff.
    ///
    /// `recordsLastInput` (the phone's text path) or an ambient dispatch (`ambientInputDispatch`) makes a delivered
    /// handoff this connection's last input to the target (#370), recorded in the same actor turn that confirmed
    /// the captured selection. A refused, unconfirmed or ownerless handoff records nothing.
    func deliver(_ input: consuming AuthorizedInput, recordsLastInput: Bool = false) async -> HostDeliveryOutcome {
        let recordsInput = recordsLastInput || Self.ambientInputDispatch
        guard admitsInput(to: input.target) else {
            return .refused(.notAllowed, "select the destination before speaking")
        }
        do {
            let generation = selectionGeneration
            let owner = try await replyOwnership(for: input, generation: generation)
            // Legacy generic input has no retained record, so the captured selection is checked here and
            // again after the handoff; a caller outside the peer's serialized receive loop can race `select`.
            guard selects(input.target, generation: generation) else {
                if let owner { replyRequests[owner.context.id] = nil }
                return .selectionChanged
            }
            switch try await send(input, owner: owner) {
            case .delivered:
                return handedOff(input.target, owner: owner, generation: generation, recordsInput: recordsInput)
            case .needsConfirmation:
                if let owner { replyRequests[owner.context.id] = nil }
                return .confirmationRequired
            }
        } catch AdapterError.deliveryFailed(let message) where message == PastedContent.agentOnlyRefusal {
            // The tmux pane was not running an agent (#608): said plainly, as a paste refusal the device keeps.
            return .refused(.notAllowed, PastedContent.agentOnlyRefusal)
        } catch {
            return .refused(deliveryCode(error), "target action was refused")
        }
    }

    /// After a complete handoff, with no suspension: commit the owner's record, or recheck the captured selection for
    /// legacy generic input. Only a `.delivered` outcome records the last input device (#370).
    private func handedOff(
        _ target: String, owner: HostReplyOwnership?, generation: UUID, recordsInput: Bool
    ) -> HostDeliveryOutcome {
        let outcome: HostDeliveryOutcome = if let owner {
            commit(owner.context, generation: generation)
        } else if selects(target, generation: generation) {
            .delivered(request: nil)
        } else {
            .unowned("request destination changed")
        }
        if recordsInput, case .delivered = outcome { noteLastInput(to: target, generation: generation) }
        return outcome
    }

    /// The captured selection authority: still negotiated, same selection generation, and a target the selection
    /// covers (the selected target, or a voice route while a route is selected, #636).
    private func selects(_ target: String, generation: UUID) -> Bool {
        guard case .ready = state else { return false }
        return generation == selectionGeneration && covers(target)
    }

    private func commit(_ context: ProviderTurnContext, generation: UUID) -> HostDeliveryOutcome {
        guard selects(context.binding.targetID, generation: generation), var request = replyRequests[context.id] else {
            return .unowned("request destination changed")
        }
        request.committed = true
        guard request.withAuthority({
            guard request.isCurrent(at: requestClock()) else { return false }
            replyRequests[context.id] = request
            return true
        }) == true else {
            replyRequests[context.id] = nil
            return .unowned("reply authority changed")
        }
        return .delivered(request: context.id)
    }

    private func send(_ input: borrowing AuthorizedInput, owner: HostReplyOwnership?) async throws -> SendOutcome {
        let (text, target, device) = (input.text, input.target, input.device)
        let expectedBinding = owner?.context.binding.sessionID ?? input.expectedBinding
        do {
            // A framed paste (#608) gets the paste line cap; every other gate is the same.
            return try await HailHost.$pastedIngress.withValue(input.carriesPaste) {
                if let owner, owner.contextual {
                    return try await host.send(text, context: owner.context, from: device)
                }
                // Legacy generic input. An unleased ambient record (#230) pins the exact binding it was minted for.
                return try await host.send(text, to: target, from: device, expectedBinding: expectedBinding)
            }
        } catch {
            if let owner { replyRequests[owner.context.id] = nil }
            throw error
        }
    }

    /// Capability preflight does not grant execution. HailHost still checks shape, exact binding and policy.
    private func replyOwnership(
        for input: borrowing AuthorizedInput, generation: UUID
    ) async throws -> HostReplyOwnership? {
        let target = input.target
        let listing = try await host.registry.listing()
        guard let listed = listing.first(where: { $0.info.id == target }), let binding = listed.binding,
              listed.info.alive else { throw HostError.unknownTarget(target) }
        if let expected = input.expectedBinding, expected != binding { throw HostError.denied(.rebound(target)) }
        var context = ProviderTurnContext(
            utteranceID: input.utteranceID, connectionID: connectionID,
            binding: try .init(hostID: hostName, providerID: listed.info.kind, targetID: target, sessionID: binding)
        )
        let contextual: Bool
        do {
            // A contextual adapter always keeps its own fresh, out-of-band context id; a bound ambient reference is
            // never used for it, so the id cannot be one a model prompt carried.
            try await host.registry.requireInputDelivery(to: target, context: context, lineCount: 1)
            contextual = true
        } catch RegistryError.contextualDeliveryUnsupported {
            // Legacy generic input cannot establish a private reply recipient on its own. Only a reference the host
            // minted for this ambient handoff and wrote into its reply block (#230) is recorded, host-side, unleased.
            guard let reference = Self.ambientReplyReference else { return nil }
            context = ProviderTurnContext(id: reference, utteranceID: context.utteranceID,
                                          connectionID: context.connectionID, binding: context.binding)
            contextual = false
        }
        // Listings are snapshots, not leases. Contextual adapters without cooperative binding authority
        // refuse before dispatch; they must not masquerade as safe private reply bridges.
        let lease = contextual ? try await host.registry.acquireReplyBindingLease(context.binding) : nil
        guard let permit = await host.replyPublicationPermit(for: context.binding) else {
            throw HostError.denied(.notAllowed(target))
        }
        try recordOwner(context, generation: generation, permit: permit, lease: lease)
        return HostReplyOwnership(context: context, contextual: contextual)
    }

    /// The record is minted only while the captured selection still holds, under capacity, never over another.
    private func recordOwner(
        _ context: ProviderTurnContext, generation: UUID, permit: ReplyPublicationPermit,
        lease: ProviderReplyBindingLease?
    ) throws {
        let target = context.binding.targetID
        pruneReplyRequests()
        guard case .ready = state, generation == selectionGeneration, covers(target) else {
            throw HostError.denied(.notAllowed(target))
        }
        guard replyRequests.count < HostReplyRequest.capacity else { throw ProviderContractError.capacityExceeded }
        guard replyRequests[context.id] == nil else { throw HostError.denied(.notAllowed(target)) }
        var request = HostReplyRequest(
            context: context, generation: generation, createdAt: requestClock(),
            policyPermit: permit, bindingLease: lease
        )
        request.awaitsTurnEnd = providerTurnEndsReported
        replyRequests[context.id] = request
    }

    private func route(_ control: ControlPayload, version: Int) async -> HostSessionResult {
        switch control {
        case .ping(let nonce):
            return HostSessionResult(frames: [response(.pong(nonce: nonce), version: version)])
        case .listTargets:
            return await listTargets(version: version)
        case .select(let targetID):
            return await select(targetID, version: version)
        case .escape(let targetID):
            return await escape(targetID, version: version)
        case .overheardScope(let scope):
            // Already a closed-vocabulary value (the decoder refuses anything else); nothing is sent back.
            overheardScope = scope
            return HostSessionResult(frames: [])
        case .hello:
            return failure(.malformed, "hello already received", close: true, version: version)
        default:
            return failure(.unauthorized, "connection probe is read-only", close: false, version: version)
        }
    }

    private func listTargets(version: Int) async -> HostSessionResult {
        do {
            return HostSessionResult(frames: [response(.targets(named(try await policyFilteredTargets())),
                                                       version: version)])
        } catch {
            return failure(.malformed, "target listing unavailable", close: false, version: version)
        }
    }

    private func select(_ targetID: String, version: Int) async -> HostSessionResult {
        do {
            guard try await policyFilteredTargets().contains(where: { $0.id == targetID && $0.alive }) else {
                return failure(.notAllowed, "target is unavailable or not allowed", close: false, version: version)
            }
            if selectedTarget != targetID {
                selectionGeneration = UUID()
                replyRequests.removeAll()
                selectedTarget = targetID
            }
            return HostSessionResult(frames: [])
        } catch {
            return failure(.malformed, "target selection unavailable", close: false, version: version)
        }
    }

    private func escape(_ targetID: String, version: Int) async -> HostSessionResult {
        guard targetID == selectedTarget else {
            return failure(.notAllowed, "select the destination before sending Escape", close: false, version: version)
        }
        do {
            try await host.escape(targetID)
            return HostSessionResult(frames: [])
        } catch {
            return deliveryFailure(error, version: version)
        }
    }

    private func deliveryFailure(_ error: any Error, version: Int) -> HostSessionResult {
        failure(deliveryCode(error), "target action was refused", close: false, version: version)
    }

    /// The code a refused request is answered with (#608): `paste_refused` in place of `not_allowed` or `malformed` for
    /// a request that carried a paste, from a device that takes request refusals. Every other code, lockdown and
    /// rate limits included, and every other request, keeps its own.
    static func refusalCode(_ code: ErrorCode, carriesPaste: Bool, takesRequestRefusals: Bool) -> ErrorCode {
        carriesPaste && takesRequestRefusals && (code == .notAllowed || code == .malformed) ? .pasteRefused : code
    }

    /// `paste_refused` for a device that advertised `request_refusals`; `code` otherwise, as before (#608).
    private func pasteRefusal(_ code: ErrorCode) -> ErrorCode {
        peerCapabilities.contains(RequestRefusals.capability) ? .pasteRefused : code
    }

    private func deliveryCode(_ error: any Error) -> ErrorCode {
        switch error {
        case HostError.unknownTarget: .unknownTarget
        case HostError.denied(.lockdown): .lockdown
        case ProviderContractError.capacityExceeded: .rateLimited
        case is HostError, is AdapterError, is RegistryError: .notAllowed
        default: .malformed
        }
    }

    /// The owner's voice routes (#636) over the policy-filtered listing: a listed route shows its name, and a route
    /// that is not listed, allowed and bound shows as offline (`alive: false`) so the device can say so rather than
    /// hide it. Names change only what is shown. Ids, policy and selection are untouched, and `select` reads the
    /// unnamed listing, so an offline route cannot be selected.
    private func named(_ targets: [TargetInfo]) -> [TargetInfo] {
        #if os(macOS)
        guard let routes = authorizer.voiceRoutes else { return targets }
        var named = targets.map { target in
            var target = target
            if let route = routes.route(for: target.id) { target.name = route.name }
            return target
        }
        for route in routes.routes where !targets.contains(where: { $0.id == route.target }) {
            let kind = route.target.prefix { $0 != ":" }
            named.append(TargetInfo(id: route.target, kind: String(kind), name: route.name, alive: false))
        }
        return named.sorted { $0.id < $1.id }
        #else
        return targets
        #endif
    }

    func policyFilteredTargets() async throws -> [TargetInfo] {
        let listing = try await host.registry.listing()
        guard let policy = await host.refreshedPolicy() else { return [] }
        return listing.compactMap { listed in
            guard let allowed = policy.targets[listed.info.id], allowed.binding == listed.binding else { return nil }
            return listed.info
        }
    }
}
