#!/usr/bin/env python3
"""rec transcription benchmark — jul/2026.

Transcribes each corpus audio with each candidate model, saves raw outputs to
results/<model>__<audio>.txt and timing/usage to results/summary.json.
Stdlib only. Keys: OPENAI_API_KEY (arg/env), GEMINI_API_KEY (env).
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
RESULTS = os.path.join(HERE, "results")

OPENAI_KEY = sys.argv[1] if len(sys.argv) > 1 else os.environ["OPENAI_API_KEY"]
GEMINI_KEY = os.environ["GEMINI_API_KEY"]

OPENAI_MODELS = [
    ("whisper-1", "verbose_json"),
    ("gpt-4o-mini-transcribe", "json"),
    ("gpt-4o-transcribe-diarize", "diarized_json"),
]
GEMINI_MODELS = ["gemini-3.5-flash", "gemini-flash-lite-latest"]

GEMINI_PROMPT = (
    "Transcribe this meeting audio verbatim, in its original language "
    "(Brazilian Portuguese). Label each turn with a speaker (Speaker 1, "
    "Speaker 2, ...). Output only the transcript, no commentary."
)


def post(url, data, headers, timeout=300):
    req = urllib.request.Request(url, data=data, headers=headers)
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()
    return time.time() - t0, body


def openai_transcribe(model, response_format, path):
    boundary = uuid.uuid4().hex
    with open(path, "rb") as f:
        audio = f.read()
    parts = []
    for name, value in [("model", model), ("response_format", response_format)]:
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; "
            f'name="{name}"\r\n\r\n{value}\r\n'.encode()
        )
    parts.append(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f'filename="{os.path.basename(path)}"\r\n'
        f"Content-Type: audio/mpeg\r\n\r\n".encode()
    )
    body = b"".join(parts) + audio + f"\r\n--{boundary}--\r\n".encode()
    headers = {
        "Authorization": f"Bearer {OPENAI_KEY}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }
    try:
        secs, raw = post("https://api.openai.com/v1/audio/transcriptions", body, headers)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        if response_format != "json":  # e.g. diarized_json unsupported -> retry plain
            print(f"    {model}: {response_format} failed ({e.code}), retrying json")
            return openai_transcribe(model, "json", path)
        raise RuntimeError(f"{model}: HTTP {e.code} {detail}")
    data = json.loads(raw)
    if response_format == "diarized_json" and "segments" in data:
        text = "\n".join(
            f"[{s.get('speaker', '?')}] {s.get('text', '')}" for s in data["segments"]
        )
    else:
        text = data.get("text", raw.decode(errors="replace"))
    return secs, text, data.get("usage")


def gemini_transcribe(model, path):
    with open(path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode()
    payload = json.dumps({
        "contents": [{"parts": [
            {"text": GEMINI_PROMPT},
            {"inline_data": {"mime_type": "audio/mp3", "data": audio_b64}},
        ]}],
        "generationConfig": {"temperature": 0},
    }).encode()
    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{model}:generateContent?key={GEMINI_KEY}"
    )
    try:
        secs, raw = post(url, payload, {"Content-Type": "application/json"})
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{model}: HTTP {e.code} {e.read().decode(errors='replace')[:300]}")
    data = json.loads(raw)
    text = "".join(
        p.get("text", "")
        for c in data.get("candidates", [])
        for p in c.get("content", {}).get("parts", [])
    )
    return secs, text, data.get("usageMetadata")


def main():
    os.makedirs(RESULTS, exist_ok=True)
    audios = sorted(
        f for f in os.listdir(CORPUS) if f.endswith(".mp3")
    )
    summary = []
    runs = [(m, rf, "openai") for m, rf in OPENAI_MODELS] + [
        (m, None, "gemini") for m in GEMINI_MODELS
    ]
    for audio in audios:
        path = os.path.join(CORPUS, audio)
        for model, rf, api in runs:
            label = f"{model}__{os.path.splitext(audio)[0]}"
            out = os.path.join(RESULTS, label + ".txt")
            if os.path.exists(out):
                print(f"skip {label} (exists)")
                continue
            print(f"run  {label} ...", flush=True)
            try:
                if api == "openai":
                    secs, text, usage = openai_transcribe(model, rf, path)
                else:
                    secs, text, usage = gemini_transcribe(model, path)
            except Exception as e:
                print(f"    FAILED: {e}")
                summary.append({"model": model, "audio": audio, "error": str(e)})
                continue
            with open(out, "w") as f:
                f.write(text)
            entry = {
                "model": model, "audio": audio, "latency_s": round(secs, 1),
                "chars": len(text), "usage": usage,
            }
            summary.append(entry)
            print(f"    ok {secs:.1f}s, {len(text)} chars")
    with open(os.path.join(RESULTS, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    print("done")


if __name__ == "__main__":
    main()
