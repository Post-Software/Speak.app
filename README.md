# Speak (Local-Only)

A macOS menu bar microapp that records audio, transcribes locally with `faster-whisper`, and inserts the text into the focused app.

## Features
- Menu bar only (no Dock icon) with green idle and red recording status.
- Global hotkey: configurable double‑tap modifier to toggle recording.
- System sounds for mic on/off (same system sound set macOS uses for recording cues).
- Local transcription with `faster-whisper` (offline by default).
- Bundled `medium` model (no downloads for end users).
- English-only transcription with a persistent model worker for faster repeat use.
- Paste at cursor via clipboard (restores clipboard), optional typing fallback.

## Project Layout
- `STTMenuBar/` — Swift AppKit app (menu bar, hotkey, recording, paste).
- `python/` — Local transcription runner using `faster-whisper`.
- `models/medium` — Bundled model folder used for offline transcription.

## Build (Xcode)
1. Open `STTMenuBar/STTMenuBar.xcodeproj` in Xcode.
2. Select a Signing Team if needed.
3. Build and Run.

The app is menu bar‑only (`LSUIElement = true`).
The build includes a script phase that bundles `python/.venv` and `models/large-v3` into the `.app`. The build will fail if those folders are missing.
The build step copies this venv into the app bundle, so end users never need Python installed.

## Model Bundling (Medium Only)
Download the `medium` model into `models/medium` once on the developer machine:

```bash
python/.venv/bin/python -m pip install -U huggingface_hub
python/.venv/bin/python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="Systran/faster-whisper-medium",
    local_dir="models/medium",
    local_dir_use_symlinks=False
)
print("Download complete.")
PY
```

The Xcode build phase bundles this model inside the app, so the shipped app works fully offline with no downloads.

## Usage
- Double‑tap Option (⌥) to start/stop recording.
- Menu bar icon turns red while recording.
- On stop: audio is transcribed locally and pasted into the active app.

Menu bar menu:
- Start / Stop Recording
- Hotkey
- Toggle sounds
- Pre-warm Model on Launch
- Quit

## Permissions
- Microphone: required to record.
- Accessibility: required to paste/insert text globally and to receive global hotkey events in some macOS configurations.

## System Sounds
Uses system recording cue sounds:
- `/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/begin_record.caf`
- `/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/end_record.caf`
