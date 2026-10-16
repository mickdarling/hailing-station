# Existing capture under competing clients and interruptions (#524)

The Mac monitor now registers configuration notifications only on its two owned
AVAudioEngine instances. Apple's SDK header instructs registration with object:engine.
The existing device-property, default-output, sleep/logout and fixed-binding checks
remain. An unrelated engine notification or ordinary app focus loss cannot revoke a
healthy owned topology; a change to either owned engine still fences immediately on
the notification thread before joined MainActor cleanup. No engine is deallocated in
the notification callback.

Private capture uses the existing AVAudioEngineCapture watchdog with a five-second
no-buffer limit, one-second checks and zero automatic restarts. A live engine flag is
not proof of useful capture. A stalled private source ends its stream and closes the
foreground run. A deliberate fresh Start reuses the existing capture implementation
with a new session, without old termination/notification cleanup stopping its successor.
Ambient capture retains its separate preexisting restart policy.

MacCoachingInterruptionSimulationTests composes the original capture, audio owner,
monitor and foreground classes with authored engine operations/clocks. It covers
unrelated-engine/focus events with queued speech, input/output owned-engine loss,
immediate revocation, delayed cleanup after fresh begin, five-second silent stall,
foreground retirement and clean explicit restart with new buffers. Existing capture
run-identity, stall, property and ownership suites remain applicable.

Actual same-device competing-client diagnostics separately completed three on/off
cycles while original capture and generated Jarvis speaker playback continued, with
stable bindings and unchanged OS defaults. That is not an exact reproduction of
Superwhisper's executable, an AirPods loudness measurement or headphone privacy proof.
No replacement capture backend, system-default/permission/driver/volume change, raw
user recording or implicit restart is introduced.
