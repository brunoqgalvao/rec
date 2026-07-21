# rec — design (2026-07-20)

Minimal macOS meeting recorder, sibling of `talk`. One `main.swift`, Makefile,
no dependencies. Approved by Bruno 2026-07-20.

## What it is

Menu bar app that records system audio + mic during meetings, transcribes via
one API provider, and writes plain files. Files are the API.

## v1

- **Capture**: ScreenCaptureKit system audio (2×2px video trick, validated in
  ambien's `AudioCaptureManager.swift`) + mic via `AVAudioEngine`, mixed in
  real time (soft-limiter) into a single M4A, bitrate tuned so ~1h fits API
  upload limits. Signed with the stable Apple Development identity.
- **Trigger**: manual only — click menu bar icon to start/stop; icon pulses
  red while recording. No call auto-detection (Anarlog keeps running in
  parallel as safety net).
- **Transcription**: one provider, winner of the jul/2026 benchmark (candidate:
  current Gemini Flash — native diarization, BYO key). On stop: upload, save
  result. On failure: keep audio, mark pending, `rec retry`.
- **Storage** (no database):
  ```
  ~/recordings/2026-07-20-1830-meeting-name/
    audio.m4a
    transcript.json   # raw provider output: words + speakers + timestamps
    meeting.md        # readable transcript with speakers, for humans and grep
  ```
  Plain files are the v1 agent API; also the seam for the future cloud hub
  (phase 2 = a separate syncer app that uploads the folder).

## Explicitly out of v1

Call auto-detection, summaries/action items (agents read `meeting.md`),
speaker naming via embeddings, multiple providers, search, listing UI
(menu → Recordings opens folder in Finder).

## Sequence

1. Re-run transcription benchmark (jul/2026 models) on real Anarlog session
   audio (PT-BR!) → pick the provider.
2. Build rec v1.
3. Cloud hub (talk + rec folders → cloud, agent access, workspaces) is its own
   later design.

## Lineage

- ambien/ami-like (~/Code): recording core reference; benchmark tool in
  `ami-like/benchmark/` (jan/2026 verdict: Gemini Flash > AssemblyAI >
  OpenAI, superseded by this benchmark).
- Anarlog: current de-facto recorder; local whisper+pyannote; MCP read-only.
