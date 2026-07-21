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
GEMINI_KEY = os.environ.get("GEMINI_API_KEY", "")
OPENROUTER_KEY = os.environ.get("OPENROUTER_API_KEY", "")
ASSEMBLYAI_KEY = os.environ.get("ASSEMBLYAI_API_KEY", "")

OPENAI_MODELS = [
    ("whisper-1", "verbose_json"),
    ("gpt-4o-mini-transcribe", "json"),
    ("gpt-4o-transcribe-diarize", "diarized_json"),
]
GEMINI_MODELS = ["gemini-3.5-flash", "gemini-flash-lite-latest"] if GEMINI_KEY else []
OPENROUTER_MODELS = (
    ["google/gemini-3.5-flash", "google/gemini-3.1-flash-lite"] if OPENROUTER_KEY else []
)

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
    fields = [("model", model), ("response_format", response_format)]
    if "diarize" in model:
        fields.append(("chunking_strategy", "auto"))
    for name, value in fields:
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


def openrouter_transcribe(model, path):
    with open(path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode()
    payload = json.dumps({
        "model": model,
        "temperature": 0,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": GEMINI_PROMPT},
            {"type": "input_audio", "input_audio": {"data": audio_b64, "format": "mp3"}},
        ]}],
    }).encode()
    headers = {
        "Authorization": f"Bearer {OPENROUTER_KEY}",
        "Content-Type": "application/json",
    }
    try:
        secs, raw = post("https://openrouter.ai/api/v1/chat/completions", payload, headers)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{model}: HTTP {e.code} {e.read().decode(errors='replace')[:300]}")
    data = json.loads(raw)
    if "error" in data:
        raise RuntimeError(f"{model}: {json.dumps(data['error'])[:300]}")
    text = data["choices"][0]["message"]["content"]
    return secs, text, data.get("usage")


def assemblyai_transcribe(path):
    headers = {"authorization": ASSEMBLYAI_KEY}
    with open(path, "rb") as f:
        audio = f.read()
    t0 = time.time()
    _, raw = post("https://api.assemblyai.com/v2/upload", audio,
                  {**headers, "Content-Type": "application/octet-stream"})
    upload_url = json.loads(raw)["upload_url"]
    payload = json.dumps({
        "audio_url": upload_url,
        "speaker_labels": True,
        "language_code": "pt",
        "speech_model": "best",
    }).encode()
    _, raw = post("https://api.assemblyai.com/v2/transcript", payload,
                  {**headers, "Content-Type": "application/json"})
    tid = json.loads(raw)["id"]
    while True:
        req = urllib.request.Request(
            f"https://api.assemblyai.com/v2/transcript/{tid}", headers=headers)
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
        if data["status"] in ("completed", "error"):
            break
        time.sleep(3)
    secs = time.time() - t0
    if data["status"] == "error":
        raise RuntimeError(f"assemblyai: {data.get('error')}")
    utts = data.get("utterances") or []
    if utts:
        text = "\n".join(f"[{u['speaker']}] {u['text']}" for u in utts)
    else:
        text = data.get("text") or ""
    return secs, text, {"audio_duration": data.get("audio_duration")}


def main():
    os.makedirs(RESULTS, exist_ok=True)
    audios = sorted(
        f for f in os.listdir(CORPUS) if f.endswith(".mp3")
    )
    summary_path = os.path.join(RESULTS, "summary.json")
    summary = []
    if os.path.exists(summary_path):  # accumulate across partial runs
        summary = [e for e in json.load(open(summary_path)) if "error" not in e]
    runs = (
        [(m, rf, "openai") for m, rf in OPENAI_MODELS]
        + [(m, None, "gemini") for m in GEMINI_MODELS]
        + [(m, None, "openrouter") for m in OPENROUTER_MODELS]
        + ([("assemblyai-best", None, "assemblyai")] if ASSEMBLYAI_KEY else [])
    )
    for audio in audios:
        path = os.path.join(CORPUS, audio)
        for model, rf, api in runs:
            label = f"{model.replace('/', '-')}__{os.path.splitext(audio)[0]}"
            out = os.path.join(RESULTS, label + ".txt")
            if os.path.exists(out):
                print(f"skip {label} (exists)")
                continue
            print(f"run  {label} ...", flush=True)
            try:
                if api == "openai":
                    secs, text, usage = openai_transcribe(model, rf, path)
                elif api == "gemini":
                    secs, text, usage = gemini_transcribe(model, path)
                elif api == "openrouter":
                    secs, text, usage = openrouter_transcribe(model, path)
                else:
                    secs, text, usage = assemblyai_transcribe(path)
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
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    print("done")


if __name__ == "__main__":
    main()
