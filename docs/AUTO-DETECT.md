# Auto-detecting meetings — recipe (research 2026-07-20)

What Anarlog/Hyprnote actually does (fork surveyed at
`~/Documents/dev-bruno/anarlog`), distilled for a future rec version. The key
finding: **no app/window watching**. The single start trigger is *another
process began capturing the microphone*, observed via CoreAudio. Everything
else is enrichment.

## The signal

1. **Coarse trigger** (event-driven, no polling): listener on the default
   input device for `kAudioDevicePropertyDeviceIsRunningSomewhere` via
   `AudioObjectAddPropertyListenerBlock`. Second listener on
   `kAudioHardwarePropertyDefaultInputDevice` (system object) to re-bind when
   the user switches mics.
2. **Which app** (macOS 14.4+): enumerate
   `kAudioHardwarePropertyProcessObjectList`, read
   `kAudioProcessPropertyIsRunningInput` per process object,
   `kAudioProcessPropertyPID` → `NSRunningApplication` → bundle id.
   Poll ~1Hz only while the coarse flag is true.

## Precision filters (what makes it not annoying)

- Ignore own bundle id.
- **Deny-list by category**, treat *unknown* bundles as meeting candidates:
  dictation (superwhisper, Voice Memos…), IDEs, screen recorders (Loom, OBS,
  CleanShot), AI assistants (ChatGPT, Claude), Raycast/GarageBand. Zoom/Teams/
  Slack pass because they're unknown/uncategorized. (Anarlog:
  `plugins/detect/src/policy.rs`.)
- **15s dwell** before acting (kills voice notes and Siri blips) + 500ms
  debounce + **10min cooldown** per app after a prompt.
- **Prompt, don't auto-record**: notification "Are you in a meeting?" with a
  Record button and an "Ignore <App>?" escape hatch. Personalized from the
  calendar when an event is ±15min ("Are you in <Event> right now?").

## End detection

Trigger app's `IsRunningInput` goes false → wait a beat → re-snapshot the
mic-user list to confirm (guards mid-call device switches) → stop. Ambiguous
cases get a "Did your meeting end? stopping in Ns" prompt. Sleep
(`NSWorkspaceWillSleepNotification`) stops immediately.

## What NOT to copy

- ambien's approach (`~/Code/ami-like/MeetingRecorder/MeetingDetector.swift`,
  793 lines + 375 for WhatsApp): NSWorkspace polling + CGWindowList titles +
  AppleScript/AX browser scraping — per-app heuristics, fragile, needs
  Accessibility. Anarlog only uses AX for Zoom *mute state* sync, never for
  detection.
- Browser tab URL reading: even Anarlog doesn't do it — platform icon comes
  from the calendar event's meeting link.

## rec sizing

The whole recipe is a few hundred lines of Swift: two CoreAudio listeners, a
1Hz process-object diff while active, a deny-list, one timer, one
notification (UNUserNotificationCenter). Calendar titles later via EventKit
(±15min window at prompt time).
