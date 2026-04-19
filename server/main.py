"""
Minimal FastAPI server for the lung monitor MVP.

POST /analyze — upload a WAV file; it is saved under ./uploads and a dummy JSON result is returned.
"""

from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile

# Folder next to this file where uploaded WAVs are stored
UPLOAD_DIR = Path(__file__).resolve().parent / "uploads"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Lung Monitor MVP", version="0.1.0")


@app.get("/")
def read_root():
    """Health check and short hint for beginners."""
    return {
        "message": "Lung Monitor API is running.",
        "hint": "POST a WAV file as form field 'file' to /analyze",
    }


@app.post("/analyze")
async def analyze(file: UploadFile = File(...)):
    """
    Accept one uploaded WAV file, save it locally, return dummy analysis JSON.
    """
    if file.filename is None or not file.filename.lower().endswith(".wav"):
        raise HTTPException(
            status_code=400,
            detail="Please upload a file whose name ends with .wav",
        )

    # Use only the base name so paths like ../../etc/passwd cannot escape the folder
    safe_name = Path(file.filename).name
    dest = UPLOAD_DIR / safe_name

    # If the same name was uploaded before, add _1, _2, ... before the extension
    if dest.exists():
        stem, suffix = dest.stem, dest.suffix
        n = 1
        while True:
            candidate = UPLOAD_DIR / f"{stem}_{n}{suffix}"
            if not candidate.exists():
                dest = candidate
                break
            n += 1

    data = await file.read()
    dest.write_bytes(data)

    return {
        "filename": dest.name,
        "file_size_bytes": len(data),
        "message": "Upload received. Dummy response — no real wheeze detection yet.",
        "dummy_wheeze_count": 0,
    }
