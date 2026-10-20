public import Foundation
public import Observation

/// What the Mac menu-bar extra shows and controls (#266): connection, destination and ambient listening. The
/// station window publishes into it; the menu only reads it and asks the window's own listening control to turn
/// listening on or off. It holds no transcript, audio or host address.
@MainActor
@Observable
public final class StationMenuStatus {
    public var windowOpen = false
    public var hostCount = 0
    public var readyHostCount = 0
    /// The confirmed destination's label, for example "This Mac · build".
    public var destination: String?
    public private(set) var isListening = false
    private var listening: (token: UUID, set: @MainActor (Bool) -> Void)?

    public init() {}

    /// A listening control is available only while the window shows one for the confirmed destination.
    public var canToggleListening: Bool { windowOpen && listening != nil }

    /// Registers the window's listening control. A later registration replaces it; the token keeps an older
    /// control's late detach from clearing its successor.
    public func attachListening(isOn: Bool, set: @escaping @MainActor (Bool) -> Void) -> UUID {
        let token = UUID()
        listening = (token, set)
        isListening = isOn
        return token
    }

    public func updateListening(_ isOn: Bool, token: UUID) {
        guard listening?.token == token else { return }
        isListening = isOn
    }

    public func detachListening(token: UUID) {
        guard listening?.token == token else { return }
        listening = nil
        isListening = false
    }

    public func setListening(_ on: Bool) {
        guard canToggleListening else { return }
        listening?.set(on)
    }

    public var summary: String {
        guard windowOpen else { return "Station window closed" }
        guard hostCount > 0 else { return "No Mac set up" }
        guard readyHostCount > 0 else { return "Not connected" }
        guard let destination else { return "Connected · choose a destination" }
        return isListening ? "Listening · \(destination)" : "Ready · \(destination)"
    }
}
