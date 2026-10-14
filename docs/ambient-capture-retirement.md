# Ambient capture admission retirement

Part of #266. Turning ambient listening off invalidates its binding immediately, while stopped resources can
still be draining, constructing, requesting permission or releasing the audio session. Mac capture admission
must remain held throughout that work, including an interrupted stream no longer stored as the live streamer.

Each controller session now retains a completion barrier for permission/startup, resume, pause and final
cleanup. Its retirement callback is captured before cleanup suspends and fires only when all that session's
owned operations finish. A newer session keeps its own callback. Existing session-generation guards still
decide which activation may release the audio session; a fast core off/on retains the existing behavior.

The Mac card's explicit Stop, close, binding/scene update and startup-failure release paths join the captured
startup and stopped sessions' completion barriers. A logically off toggle is insufficient evidence of cleanup.
Canceling a caller does not release admission while the underlying resource operation remains in flight.

`AmbientRetirementJoinTests` and `AmbientRetirementOwnershipTests` use only authored permission, factory,
send and release barriers with synthetic capture streams. They cover unexpected end followed by close/update,
pause followed by Stop/close, delayed initial construction, delayed resume construction, a paused stream still
draining, pending permission, canceled release and successor callback ownership. Existing interruption,
recovery, binding and fast-restart tests remain unchanged. These checks do not qualify real audio hardware.
