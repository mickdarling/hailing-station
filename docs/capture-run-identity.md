# Capture run identity prerequisite

Part of #269. This source-only prerequisite fixes a real capture-owner restart defect discovered while
reviewing the inactive private coaching Apple adapter. It does not enable coaching or alter routing/masking.

Finishing a stream schedules its termination cleanup on the main actor. Previously that cleanup called
`stop` without identifying its run. A synchronous stop/start on the same capture owner could start a new
run before the old callback executed, letting old cleanup stop the replacement microphone stream.

Each start now allocates a private per-run UUID. Termination stops only its still-current originating run;
stop retires the UUID before finishing the continuation. The identity never leaves the capture owner or
enters logging. Current-stream cancellation still stops capture; startup failures and system-end cleanup
continue to use the ordinary stop path. The stall watchdog restarts within the same stream/run identity.

`AudioEngineCaptureRunIdentityTests` uses injected engine operations without microphone IO. Its two
replacement cases fail on the previous source (three assertion failures); the current-consumer cancellation
case already passes, guarding against fixing replacement by disabling cleanup. Both immediate stop/start
and cancelled-old-consumer/restart schedules are covered. No live audio, signing, deployment or device proof.
