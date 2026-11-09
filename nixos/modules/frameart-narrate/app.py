import os
import subprocess
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

IMAGES_DIR = Path(os.environ["FRAMEART_IMAGES_DIR"])
CACHE_DIR = IMAGES_DIR / "narration"
VOICE_MODEL = os.environ["PIPER_VOICE_MODEL"]

BLURB_PROMPT = (
    "Look at the painting image at {path}. Identify the artwork and its "
    "painter if you can tell from the image itself. Write a warm, "
    "spoken-style script of about 100-150 words: a little context about "
    "the piece, then a brief history of the painter. Plain prose only, no "
    "markdown, no headings, no quotation marks -- nothing but the words to "
    "be read aloud. If you cannot identify it confidently, say so plainly "
    "and describe what you see instead of guessing a false attribution."
)

app = FastAPI()


class NarrateRequest(BaseModel):
    filename: str


def audio_path(filename: str) -> Path:
    # Filenames come from the image listing the app already trusts, but
    # guard against path separators anyway since this ends up in a shell.
    return CACHE_DIR / f"{Path(filename).name}.wav"


def generate_blurb(image_path: Path) -> str:
    result = subprocess.run(
        [
            "claude", "-p", BLURB_PROMPT.format(path=image_path),
            "--allowed-tools", "Read",
        ],
        capture_output=True, text=True, timeout=120, check=True,
    )
    return result.stdout.strip()


def synthesize(text: str, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_suffix(".wav.tmp")
    subprocess.run(
        ["piper", "-m", VOICE_MODEL, "-f", str(tmp_path)],
        input=text, text=True, timeout=60, check=True,
    )
    tmp_path.rename(out_path)


@app.post("/narrate")
def narrate(req: NarrateRequest):
    image_path = IMAGES_DIR / Path(req.filename).name
    if not image_path.is_file():
        raise HTTPException(404, "no such image")

    out_path = audio_path(req.filename)
    if out_path.is_file():
        return {"ready": True, "path": f"narration/{out_path.name}"}

    try:
        blurb = generate_blurb(image_path)
        if not blurb:
            raise RuntimeError("empty blurb")
        synthesize(blurb, out_path)
    except Exception as e:
        raise HTTPException(502, f"narration failed: {e}")

    return {"ready": True, "path": f"narration/{out_path.name}"}
