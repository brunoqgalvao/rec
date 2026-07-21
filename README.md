# rec

Minimal meeting recorder for macOS. Click the menu bar icon (or the island
that wraps your notch), record system audio + microphone mixed into a single
file, and get a speaker-labelled transcript as plain files. No bot joins your
call. No database. No cloud of ours — your recordings stay in `~/recordings`.

Sibling of [talk](https://github.com/brunoqgalvao/talk): one Swift file, a
Makefile, no dependencies.

## How it works

- **Record**: ScreenCaptureKit captures system audio (Zoom, Meet, Teams —
  anything the Mac plays) while AVAudioEngine captures your mic; both are
  mixed in real time into one speech-tuned M4A (16kHz AAC, ~4KB/s).
- **The island**: on notch MacBooks a black shape extends from the notch with
  a red dot and a timer — hover for the stop button, click anywhere on it to
  stop. On other displays it's a small floating pill.
- **Transcribe**: AssemblyAI by default (speaker labels, `language_code` of
  your choice), falling back to local whisper.cpp when offline or keyless.
  Failures keep the audio and mark it pending — `rec retry` finishes the job.
- **Files are the API**: one folder per meeting, ready for grep, agents, and
  sync:

  ```
  ~/recordings/2026-07-20-1830/
    audio.m4a
    transcript.json   # raw provider output: words, speakers, timestamps
    meeting.md        # readable transcript with speaker turns
  ```

## Install

```sh
git clone https://github.com/brunoqgalvao/rec && cd rec
make install-app       # builds and copies rec.app to /Applications
make install           # optional: the rec CLI into /usr/local/bin
```

On first recording, grant **Screen Recording** and **Microphone** in System
Settings (rec's Settings window shows both with live status). The Makefile
signs with your Apple Development certificate when one exists so those grants
survive rebuilds; `make SIGN=-` forces ad-hoc.

## Configure

`~/.rec` takes KEY=VALUE lines (environment variables win):

```
ASSEMBLYAI_API_KEY=...   # transcription with speaker labels
ENGINE=assemblyai        # or: local (whisper.cpp, offline)
LANGUAGE=pt              # AssemblyAI/whisper language code
MIC_GAIN=10              # mic boost into the mix (1–20)
```

For the local engine: `brew install whisper-cpp` and `rec setup-local`
(downloads ggml-large-v3-turbo, ~550MB).

## CLI

```
rec check        # diagnose permissions, keys, engines
rec retry        # transcribe pending recordings
rec setup-local  # download the local whisper model
rec selftest     # unit tests
```

## License

MIT
