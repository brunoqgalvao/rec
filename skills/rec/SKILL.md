---
name: rec
description: Access meetings recorded by rec (macOS meeting recorder). Use when the user asks about a recorded meeting, "what was said in the meeting", wants a summary or action items from a call, wants to find who said something, or mentions a meeting transcript ("reunião", "resumo da call", "transcrição").
---

# rec — recorded meetings

rec (menu bar app) records meetings (system audio + mic) and saves everything as files under `~/recordings/` — **files are the API**, no database, no server. One folder per meeting:

```
~/recordings/2026-07-21-1028/
  audio.m4a          # meeting audio (AAC 16kHz mono)
  transcript.json    # raw provider output: words, speakers, timestamps (ms)
  meeting.md         # readable transcript with speaker turns **[A]**/**[B]**/…
  transcript.pending # only exists if transcription failed (contains the reason)
```

## CLI (prefer for discovery/search)

```sh
rec list             # meetings, newest first: id, duration, status
rec list --json      # same, as JSON (id, path, status, duration, engine)
rec show latest      # print the latest meeting's meeting.md
rec show 2026-07-21  # exact id or prefix (most recent wins)
rec search <term>    # search all transcripts, case/accent-insensitive
                     # output: <id>:<line>: excerpt (exit 1 if nothing)
rec retry            # re-transcribe pending/orphaned recordings
rec check            # diagnostics (permissions, keys, engines)
```

## Reading files directly (for deeper analysis)

- `meeting.md` — normal Read/grep; each speaker turn is one line: `**[X]** text`.
- `transcript.json` — when you need timestamps or individual words: `utterances[]` has `speaker`, `text`, `start`/`end` in ms; `words[]` the same per word.

## Conventions

- Speakers are anonymous A/B/C labels from the diarizer — infer who is who from content (the machine's owner is usually the one speaking closest to the mic and referenced by name). More than one person in a call can share a name.
- Meeting id = folder name = `yyyy-MM-dd-HHmm` (start time).
- Status `pending` = audio without a transcript (failure, or the app died while recording); `rec retry` tries again. If `transcript.pending` shows a transcoding error, the audio is corrupted and unrecoverable.
- For summaries/action items: read the whole `meeting.md` and synthesize — rec does not generate summaries itself (yet).
