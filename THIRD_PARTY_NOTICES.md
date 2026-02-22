# Third-Party Notices

Speak includes or depends on third-party components and model sources.

## Model Sources

1. **Voxtral Mini 4B Realtime 2602**
- Source: https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602
- License: Apache-2.0

2. **Voxtral Mini Q4 GGUF (community)**
- Source: https://huggingface.co/TrevorJS/voxtral-mini-realtime-gguf
- License: Apache-2.0 (per upstream project metadata)

## Runtime Dependencies

1. **voxtral-mini-realtime-rs**
- Source: https://github.com/TrevorS/voxtral-mini-realtime-rs
- License: Apache-2.0

2. **speak-to (reference architecture)**
- Source: https://github.com/mekza/speak-to
- License: Apache-2.0

3. **Rust crates**
- Includes crates from crates.io and Git dependencies referenced in `rust-transcriber/Cargo.toml`.
- Each crate retains its own license terms.

## Distribution Notes

- Speak does not bundle Voxtral model weights in the repository or release package.
- Model files are downloaded locally at runtime after explicit user consent.
