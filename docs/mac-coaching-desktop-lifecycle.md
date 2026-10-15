# Desktop coaching while using a meeting app

Part of #525 and #524. An explicitly started Mac coaching session must continue when the owner switches
to Teams, Zoom, dictation, or another desktop app. Losing application focus is not evidence of device loss.
The Mac card no longer requests Stop for a SwiftUI scene-phase change, and the native monitor no longer
subscribes to NSApplication.didResignActiveNotification.

The visible Stop button, view disappearance/window closure, normal joined Quit, audio graph/device or
binding loss, workspace sleep and session logout/inactivation still revoke capture and private playback.
The existing qualification/renewal/deadline rules are unchanged. This is Mac-only behavior; the iOS adapter
keeps its background lifecycle restrictions. Starting is still explicit and participant-aware.

Authored tests use the same default native notification policy with isolated app/workspace centers:
app switching preserves qualification, sleep/logout and engine changes retire it, and release removes
workspace observers. Existing ownership/Quit/route tests remain applicable. Actual microphone continuity,
provider output and interaction with dictation require separate physical proof. This prerequisite does
not implement system/conference audio capture or prove Teams/Zoom compatibility.
