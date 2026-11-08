/// Operation-bearing delivery admission requires an explicit capability and exactly one operation.
public enum DeliveryAdmissionError: Error, Sendable, Equatable {
    case unsupported
    case invalidGate
}

/// Operation-bearing delivery admission is ordered against retirement by nesting retained authority gates.
/// Each gate must hold its original authority through the supplied operation, or throw without invoking it.
/// Retirement uses those same gates. Once retirement completes, no later operation is admitted;
/// an operation admitted before retirement may complete. No gate is held through asynchronous completion.
struct DeliveryAdmission: Sendable {
    /// This order must agree with publication paths. In particular, target policy is acquired once;
    /// task output must validate the retained generation without reacquiring its target-policy gate.
    enum Stage: CaseIterable, Hashable, Sendable {
        case targetPolicy
        case taskOutputFence
        case replyPermit
        case bindingLease
        case sessionUpdateFence
        case ambientRouter
        case privacyHold
        case peerLifecycle
        case attemptCancellation
    }

    struct Gate: Sendable {
        /// Validation reads authority only: it must commit neither cancellation nor attempts.
        let validate: @Sendable () throws -> Void
        /// Invoke the nonescaping operation exactly once under the gate, or throw without invoking it.
        /// No actor hop, I/O completion wait, retirement or gate re-entry is permitted inside the operation.
        let perform: @Sendable (_ operation: () throws -> Void) throws -> Void
    }

    private let gates: [Gate]

    /// Stages are unique by construction, ordered here, and skipped when absent.
    init(gates: [Stage: Gate]) {
        self.gates = Stage.allCases.compactMap { gates[$0] }
    }

    func validate() throws {
        for gate in gates { try gate.validate() }
    }

    func admit<Value>(_ operation: () throws -> Value) throws -> Value {
        var result: Result<Value, any Error>?
        try perform(at: 0) {
            result = Result(catching: operation)
            _ = try result?.get()
        }
        guard let result else { throw DeliveryAdmissionError.invalidGate }
        return try result.get()
    }

    private func perform(at index: Int, operation: () throws -> Void) throws {
        guard index < gates.count else { return try operation() }
        var invoked = false
        try gates[index].perform {
            guard !invoked else { throw DeliveryAdmissionError.invalidGate }
            invoked = true
            try perform(at: index + 1, operation: operation)
        }
        guard invoked else { throw DeliveryAdmissionError.invalidGate }
    }
}
