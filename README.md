# Speak (macOS, Offline Speech-to-Text)

Speak is a menu bar app for macOS that records your voice, transcribes it locally, and inserts text into the focused app.

## What It Does
- Menu bar app (`LSUIElement`, no Dock icon).
- Green icon when idle, red icon while recording.
- Toggle recording from:
  - Menu item (`Start Recording` / `Stop Recording`)
  - Global double-tap modifier hotkey (Option/Command/Control/Shift).
- Plays native macOS record start/stop sounds.
- Runs transcription fully offline after first-run setup.
- Pastes transcription into the active app and restores the previous clipboard.

## First-Run Setup
On first launch, Speak opens a setup wizard and blocks recording until setup is complete.

Step 1: Permissions
- Microphone (required)
- Accessibility (required for hotkey + auto-paste)

Step 2: Model download
- `Parakeet v3 (Default)` -> `nemo-parakeet-tdt-0.6b-v3` (Rust worker with Handy-compatible ONNX artifacts)
- `Small (Fastest)` → `Systran/faster-whisper-small.en`
- `Medium (Recommended)` → `Systran/faster-whisper-medium.en`
- `Large v3 (Best Accuracy)` → `Systran/faster-whisper-large-v3`

Speak fetches exact download size at runtime before consent.
Parakeet setup keeps the selection when runtime is installable and only auto-switches to Medium on hard unsupported runtime.

## Model Storage and Switching
- Models are stored in:
  - `~/Library/Application Support/Speak/models/<model_id>/`
- Manifest is stored at:
  - `~/Library/Application Support/Speak/models/manifest.json`
- Only one model is kept at a time.
- When switching models, Speak keeps the old model active until the new model is fully downloaded and verified, then deletes the old model.

## Offline First Launch Behavior
If no internet is available during first-run setup, model setup remains blocked and recording stays disabled until download succeeds.

## Runtime Notes
- Whisper models use bundled runtime dependencies from `python/.venv`.
- Parakeet v3 uses a bundled Rust worker (`parakeet-worker`) and Handy-compatible model layout.
- Parakeet v3 is optimized for Apple Silicon in this release; unsupported runtimes fall back to Small Whisper in setup.
- Parakeet model artifacts are downloaded from the configured tarball source (default: `https://blob.handy.computer/parakeet-v3-int8.tar.gz`).

## Repository Layout
- `STTMenuBar/` — Xcode project + Swift AppKit app.
- `python/transcribe.py` — Python transcription worker + model management commands.
- `rust/parakeet-worker/` — Rust Parakeet runtime/model worker.
- `python/requirements.txt` — Python dependencies.

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

## Release Packaging Prerequisite
Install Node dependencies before running release scripts:

```bash
npm ci
```

## In-App Updates
- Speak uses Sparkle 2 for in-app update checks and install prompts.
- Feed URL: `https://post-software.github.io/Speak.app/appcast.xml`
- First install still uses DMG. Subsequent updates are delivered in-app from signed ZIP archives.

### Sparkle Key Management
- `SUPublicEDKey` lives in `Info.plist`.
- Sparkle private key must not be committed.
- Set private key path at release time with `SPARKLE_PRIVATE_KEY_PATH=/secure/path/to/sparkle_private_key`.

### Release Script
- Canonical release command: `scripts/release.sh`
- Compatibility wrappers remain available:
  - `scripts/release_0_1_2.sh`
  - `scripts/release_0_1_3.sh`
  - `scripts/release_0_1_4.sh`

### Release Output
`scripts/release.sh` now produces:
- Signed/notarized DMG
- Sparkle update ZIP (`dist/<version>/Speak-<version>.zip`)
- Sparkle signature output (`dist/<version>/sparkle-signature.txt`)
- Sparkle appcast XML (`dist/<version>/appcast.xml`)
- Updated canonical feed file (`docs/appcast.xml`)

## How Bundling Works
Xcode build phase copies into app resources:
- `python/.venv` -> `Speak.app/Contents/Resources/python`
- `python/transcribe.py` -> `Speak.app/Contents/Resources/python/transcribe.py`
- `python/requirements-parakeet-v3.txt` -> `Speak.app/Contents/Resources/python/requirements-parakeet-v3.txt`
- `rust/parakeet-worker` -> `Speak.app/Contents/Resources/parakeet-worker`

Model weights are not bundled in the app; they are downloaded during setup.

## Notes
- No analytics or telemetry are included.
- Transcription default language is English.
- If Accessibility is not granted, Speak can still copy text to clipboard but cannot reliably paste globally.
