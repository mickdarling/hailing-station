# Fake engine callback lifetime prerequisite

Part of #269. This test-only prerequisite repairs the fake engine used by capture/ambient tests;
it changes no production audio, cleanup, deadline or verification scheduling behavior.

The native composition full run aborted on an unowned reference. Its symbolized crash stack identifies
`FakeEngineOperations.operations`' stop closure, called by `AVAudioEngineCapture.stop` from the
ambient streamer's late pump cleanup. The operation closures outlived their fixture's local scope.
Two deterministic red-before tests prove that neither the returned operations nor retained capture
kept the fixture alive. They fail before dereferencing the unsafe callback, without another broad retry.

All five operation closures now retain their authored fixture state. Regressions execute install/start/
running/remove/stop after the fixture scope ends, and perform repeated capture stop for late cleanup.
They also prove release after the operations/capture owner is released, avoiding a permanent fixture leak.
Original ambient/capture assertions remain unchanged. No real microphone, device activation, recording,
playback, speech, public write or deployment was used.
