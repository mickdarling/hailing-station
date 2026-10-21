public import Foundation
public import Observation

/// What the Mac menu-bar extra shows and controls (#266): connection, destination and ambient listening. The
/// station window publishes into it; the menu only reads it and asks the window's own listening control to turn
/// listening on or off. It holds no transcript, audio or host address.
@MainActor
@Observable
public final class StationMenuStatus {
    /// Ambient listening as the window's card shows it, so the menu never claims more than the card does.
    public enum Listening: Equatable, Sendable {
        case off
        /// On, and waiting for permission or the stream to start.
        case starting
        case listening
        /// On, but another app holds the microphone (#445); it resumes by itself.
        case paused
        /// Off here because another device took listening over (#366).
        case elsewhere

        /// Whether the switch is on: starting, listening and paused all keep it on.
        public var isOn: Bool { self == .starting || self == .listening || self == .paused }
    }

    public var windowOpen = false
    public var hostCount = 0
    public var readyHostCount = 0
    /// The confirmed destination's label, for example "This Mac · build".
    public var destination: String?
    public private(set) var listening = Listening.off
    private var control: (token: UUID, set: @MainActor (Bool) -> Void)?

    public init() {}

    /// A listening control is available only while the window shows one for the confirmed destination.
    public var canToggleListening: Bool { windowOpen && control != nil }

    /// Registers the window's listening control. A later registration replaces it; the token keeps an older
    /// control's late detach from clearing its successor.
    public func attachListening(_ state: Listening, set: @escaping @MainActor (Bool) -> Void) -> UUID {
        let token = UUID()
        control = (token, set)
        listening = state
        return token
    }

    public func updateListening(_ state: Listening, token: UUID) {
        guard control?.token == token else { return }
        listening = state
    }

    public func detachListening(token: UUID) {
        guard control?.token == token else { return }
        control = nil
        listening = .off
    }

    public func setListening(_ on: Bool) {
        guard canToggleListening else { return }
        control?.set(on)
    }

    public var summary: String {
        guard windowOpen else { return "Station window closed" }
        guard hostCount > 0 else { return "No Mac set up" }
        guard readyHostCount > 0 else { return "Not connected" }
        guard let destination else { return "Connected · choose a destination" }
        switch listening {
        case .off: return "Ready · \(destination)"
        case .starting: return "Starting to listen · \(destination)"
        case .listening: return "Listening · \(destination)"
        case .paused: return "Listening paused: another app has the mic · \(destination)"
        case .elsewhere: return "Listening on another device · \(destination)"
        }
    }
}
