# Selected Mac microphone format

Part of #269 and #268. A Mac coaching input engine can retain the previous default microphone's client format after selecting a different physical microphone. Passing that cached output format to the input tap crashes when the hardware format differs, because AVAudioInputNode cannot convert hardware input formats.

The coaching factory now applies the selected input node's hardware format to its unconnected tap bus while the engine is stopped, before creating/arming the route monitor. AVAudioEngineCapture retains that prepared tap/stream for its first explicit start. Stop removes the tap and finishes either the prepared or active stream. Shared/mobile capture continues using its original lazy preparation.

The selected-device exact readback, physical input evidence, private-output evidence, retirement, admission, and deadline checks remain mandatory. This does not accept an aggregate alias, rebind a failed owner, change system defaults, or start input during construction.

Focused authored regressions cover preparing without IO, first-start reuse, stop-before-start cleanup, and fresh subsequent runs, alongside existing startup, route, capture identity, and command tests. A bounded local physical check reproduced the original hardware/tap mismatch, then verified continuous selected USB microphone callbacks before, during, and after private headphone Jarvis playback after correction. Captured speech was discarded; only counts were retained. A human confirmed the intended voice at the normal renderer level. This is a local physical check, not a general compatibility or concurrency guarantee.

Apple documents the hardware input format and lack of input conversion in [AVAudioInputNode](https://developer.apple.com/documentation/avfaudio/avaudioinputnode), and permits a nonnil tap format to apply to an unconnected output bus in AVAudioNode's SDK contract.
