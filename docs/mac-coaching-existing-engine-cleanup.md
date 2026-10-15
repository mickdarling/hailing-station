# Existing Mac microphone connection cleanup

Part of #524. This change repairs the existing AVAudioEngine connection. It introduces no replacement
capture adapter, route, permission request, automatic restart, aggregate device or default-device write.

A refused setup can release MacCoachingAudioOwner after AVAudioEngineCapture.prepareTap but before
owner.start. Its old deinitializer called stop, whose active-revision guard skipped all cleanup in this
state. The prepared tap was therefore not explicitly removed through the capture lifecycle. The owner now tracks
whether resource cleanup ran and cleans prepared resources on destruction as well as active resources.
Successful explicit retirement remains once-only; a subsequent explicit start owns fresh cleanup.

MacCoachingPreparedCleanupTests uses the real existing capture and owner with injected engine operations.
It reproduces the skipped tap removal before the fix, and checks prepared/started lifetimes with/without
explicit Stop after the fix. No microphone, playback, provider or native render callback is started by
these tests. The broader targeted tests cover route retirement, stale generations, capture buffers,
advice and authored rendered PCM. They do not establish Superwhisper causation or physical cue audibility.

Local stopped-engine comparisons with the current OS output retained the selected physical input through
binding, tap preparation, output graph setup and ten seconds of observation. Both the existing C setter
and Apple's wrapper setter passed; there is no evidence here supporting a setter replacement. No source
setter change is made. The standalone comparison initially used an incorrect player format and aborted;
that diagnostic was corrected to the production Float32 format before these observations.

The native property-listener crash and the user's missing cue remain unresolved physical evidence.
Frequent Superwhisper use and conference/system audio requirements remain in issues #524 and #525.
