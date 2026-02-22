# Speak (macOS, Offline Speech-to-Text)

Speak is a menu bar app for macOS that records your voice, transcribes it locally with `faster-whisper`, and inserts text into the focused app.

## What It Does
- Menu bar only app (`LSUIElement`, no Dock icon).
- Green icon when idle, red icon while recording.
- Toggle recording from:
  - Menu item (`Start Recording` / `Stop Recording`)
  - Global double-tap modifier hotkey (Option/Command/Control/Shift).
- Plays native macOS record start/stop sounds.
- Runs transcription fully offline using bundled Python + bundled model.
- Pastes transcription into the active app and restores the previous clipboard.

## Current Runtime Defaults
- Model: bundled `medium`
- Language: English (`en`)
- Device: CPU
- Beam size: `1`

## Permissions
Speak needs:
- Microphone: to record audio.
- Accessibility: for global hotkey handling and global paste.

Speak shows an in-app permissions window on startup whenever either required permission is missing.

## Repository Layout
- `STTMenuBar/` — Xcode project + Swift AppKit app.
- `python/transcribe.py` — Python transcription worker entrypoint.
- `python/requirements.txt` — Python dependencies.
- `models/medium/` — local model directory bundled into app resources at build time.

## Local Build
1. Open `STTMenuBar/STTMenuBar.xcodeproj` in Xcode.
2. Select the `Speak` target and your signing team.
3. Build/Run.

## Build-Time Python Setup (Developer Machine)
The app bundles a local Python environment from `python/.venv` during build.

```bash
python3 -m venv python/.venv
python/.venv/bin/pip install -r python/requirements.txt
```

## Model Setup (Developer Machine)
Download the medium model into `models/medium`:

```bash
python/.venv/bin/python -m pip install -U huggingface_hub
python/.venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="Systran/faster-whisper-medium",
    local_dir="models/medium",
    local_dir_use_symlinks=False,
)
print("Download complete")
PY
```

## How Bundling Works
Xcode build phase copies into app resources:
- `python/.venv` -> `Speak.app/Contents/Resources/python`
- `python/transcribe.py` -> `Speak.app/Contents/Resources/python/transcribe.py`
- `models/medium` -> `Speak.app/Contents/Resources/models/medium`

End users do not need to install Python or download models.

## Manual Transcription Test
```bash
python/.venv/bin/python python/transcribe.py \
  --audio /path/to/audio.wav \
  --model models/medium \
  --language en \
  --device cpu \
  --local-only
```

## Notes
- No analytics or telemetry are included.
- If Accessibility is not granted, Speak can still copy text to clipboard but cannot reliably paste globally.
