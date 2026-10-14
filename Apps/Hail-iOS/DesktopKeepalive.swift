#if os(macOS)
import HailCore

/// macOS does not need an audio renderer to keep an ordinary window's connections alive (#266).
@MainActor
final class DesktopKeepalive: BackgroundKeepaliveRendering {
    var onEvent: (@MainActor (BackgroundKeepaliveEvent) -> Void)?
    func start() {}
    func stop(releasingSession: Bool) {}
}
#endif
