import json
import os
import subprocess
import threading
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

IMAGES_DIR = Path(os.environ["FRAMEART_IMAGES_DIR"])
CACHE_DIR = IMAGES_DIR / "narration"
VOICE_MODEL = os.environ["PIPER_VOICE_MODEL"]

NARRATION_PROMPT = (
    "Look at the painting image at {path}. Describe its distinctive subject "
    "matter, style, and any visible text (signature, title card, museum "
    "label) to yourself, then use the WebSearch tool to try to verify the "
    "artwork's title, painter, and year from those details -- a guess from "
    "visual memory alone is often wrong, so confirm it against search "
    "results before committing to an attribution. Respond with ONLY a JSON "
    "object (no markdown fences, no commentary) with exactly these keys: "
    "\"title\" (the painting's title, or \"Untitled\" if unknown), "
    "\"artist\" (the painter's name, or \"Unknown\" if you cannot tell), "
    "\"year\" (a year or short date range as a string, or \"Unknown\"), "
    "\"text\" (a warm, spoken-style script of about 100-150 words: a "
    "little context about the piece, then a brief history of the painter "
    "-- plain prose only, nothing but the words to be read aloud; if you "
    "cannot verify the piece confidently even after searching, say so "
    "plainly in this field and describe what you see instead of guessing a "
    "false attribution)."
)

app = FastAPI()

# Filenames currently being synthesized in a background thread, so a second
# /narrate call for the same picture while audio is still cooking does not
# start a duplicate piper run.
_audio_jobs = set()
_audio_jobs_lock = threading.Lock()


class NarrateRequest(BaseModel):
    filename: str


def meta_path(filename: str) -> Path:
    return CACHE_DIR / f"{Path(filename).name}.json"


def audio_path(filename: str) -> Path:
    # Filenames come from the image listing the app already trusts, but
    # guard against path separators anyway since this ends up in a shell.
    return CACHE_DIR / f"{Path(filename).name}.wav"


def generate_narration(image_path: Path) -> dict:
    result = subprocess.run(
        [
            "claude", "-p", NARRATION_PROMPT.format(path=image_path),
            "--allowed-tools", "Read", "WebSearch",
        ],
        capture_output=True, text=True, timeout=180, check=True,
    )
    raw = result.stdout.strip()
    # Claude sometimes wraps JSON in a markdown fence despite the prompt.
    if raw.startswith("```"):
        raw = raw.strip("`")
        if raw.lower().startswith("json"):
            raw = raw[4:]
        raw = raw.strip()
    data = json.loads(raw)
    return {
        "title": str(data.get("title") or "Untitled"),
        "artist": str(data.get("artist") or "Unknown"),
        "year": str(data.get("year") or "Unknown"),
        "text": str(data.get("text") or "").strip(),
    }


def synthesize(text: str, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_suffix(".wav.tmp")
    subprocess.run(
        ["piper", "-m", VOICE_MODEL, "-f", str(tmp_path)],
        input=text, text=True, timeout=60, check=True,
    )
    tmp_path.rename(out_path)


def ensure_audio(name: str, text: str) -> None:
    out_path = audio_path(name)
    if out_path.is_file():
        return
    with _audio_jobs_lock:
        if name in _audio_jobs:
            return
        _audio_jobs.add(name)
    try:
        synthesize(text, out_path)
    finally:
        with _audio_jobs_lock:
            _audio_jobs.discard(name)


@app.post("/narrate")
def narrate(req: NarrateRequest):
    name = Path(req.filename).name
    image_path = IMAGES_DIR / name
    if not image_path.is_file():
        raise HTTPException(404, "no such image")

    m_path = meta_path(name)
    if m_path.is_file():
        meta = json.loads(m_path.read_text())
    else:
        try:
            meta = generate_narration(image_path)
            if not meta["text"]:
                raise RuntimeError("empty narration text")
        except Exception as e:
            raise HTTPException(502, f"narration failed: {e}")
        m_path.parent.mkdir(parents=True, exist_ok=True)
        m_path.write_text(json.dumps(meta))

    audio_ready = audio_path(name).is_file()
    if not audio_ready:
        threading.Thread(target=ensure_audio, args=(name, meta["text"]), daemon=True).start()

    return {
        "title": meta["title"],
        "artist": meta["artist"],
        "year": meta["year"],
        "text": meta["text"],
        "audio_ready": audio_ready,
        "audio_path": f"narration/{name}.wav",
    }
