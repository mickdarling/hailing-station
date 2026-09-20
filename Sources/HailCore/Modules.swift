/// Owns the audio session: external mic in, AirPods out, device preference order (#4).
public protocol AudioSessionController: Sendable {
    func activate() async throws
    func deactivate() async
}

/// Renders frames coming back from a host: audio playback, text, later images (#7).
public protocol Renderer: Sendable {
    func render(text: String) async
}

/// One persistent connection to a host daemon (#9). Identity and sealing come from #39 and #40.
public protocol Transport: Sendable {
    var isConnected: Bool { get async }
    func connect() async throws
    func disconnect() async
}
