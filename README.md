# Speak (macOS, Local Speech-to-Text)

Speak is a menu bar app for macOS that records your voice, transcribes it locally, and inserts text into the focused app.

## What Changed
- Speak no longer bundles a huge model in the app package.
- On first launch, users choose a model tier and explicitly approve the download after seeing exact size.
- Transcription runs through a bundled Rust sidecar (`speak-transcriber`).
- Runtime policy is Metal-first, with automatic CPU fallback warning if Metal is unavailable.

## Model Tiers
- `Fast (Q4)`
  - Source: `TrevorJS/voxtral-mini-realtime-gguf`
  - Lower memory footprint, optimized for speed.
- `Quality (Full Precision)`
  - Source: `mistralai/Voxtral-Mini-4B-Realtime-2602`
  - Higher memory usage, higher quality.

The app fetches and displays exact download size at setup time before download starts.

## Permissions
Speak requires:
- Microphone (record audio)
- Accessibility (global hotkey + paste)

The permission window is built to force a reliable microphone authorization path:
- `notDetermined`: request system prompt immediately.
- `denied/restricted`: route user to System Settings and re-check after return.

## Repository Layout
- `STTMenuBar/` — Xcode project + AppKit app.
- `rust-transcriber/` — Rust sidecar worker and model manager CLI.
- `scripts/bundle_resources.sh` — builds and bundles `speak-transcriber` into app resources.

## Build
1. Install Rust toolchain (`cargo`) and Xcode tools.
2. Open `STTMenuBar/STTMenuBar.xcodeproj`.
3. Build/Run `Speak`.

During build, Xcode runs `scripts/bundle_resources.sh`, which compiles and copies:
- `rust-transcriber/target/<profile>/speak-transcriber`
- to `Speak.app/Contents/Resources/bin/speak-transcriber`

## End-User Runtime Requirements
- End users **do not** need to install Rust, Cargo, Python, or any CLI tooling.
- The shipped `.app` already contains the `speak-transcriber` runtime binary.
- Model weights are downloaded in-app on first run after explicit user consent.
- Only developers/CI building from source need Rust installed.

## Runtime Notes
- No model weights are committed to this repository.
- Model weights are downloaded at first run and stored in:
  - `~/Library/Application Support/Speak/models/`
- Model state manifest is stored at:
  - `~/Library/Application Support/Speak/models/manifest.json`

## License Notes
- App code remains under this repository's license.
- Voxtral model and Rust dependencies include third-party licenses; see `THIRD_PARTY_NOTICES.md`.
