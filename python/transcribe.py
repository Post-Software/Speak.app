#!/usr/bin/env python3
import argparse
import json
import os
import sys

from faster_whisper import WhisperModel


def parse_args():
    p = argparse.ArgumentParser(description="Local transcription with faster-whisper")
    p.add_argument("--audio", required=False, help="Path to WAV audio file")
    p.add_argument("--model", default="small", help="Model name or path")
    p.add_argument("--language", default="en", help="Language code")
    p.add_argument("--compute-type", default="auto", help="int8, float16, int8_float16, or auto")
    p.add_argument("--device", default="cpu", help="cpu or metal")
    p.add_argument("--local-only", action="store_true", help="Disable network downloads")
    p.add_argument("--allow-download", action="store_true", help="Allow model download if missing")
    p.add_argument("--beam-size", default=1, type=int, help="Beam size for decoding")
    p.add_argument("--worker", action="store_true", help="Run in persistent worker mode")
    return p.parse_args()


def resolve_compute_type(device, compute_type):
    if compute_type != "auto":
        return compute_type
    if device == "metal":
        return "float16"
    return "int8"


def transcribe_once(model, audio_path, language, beam_size):
    segments, _ = model.transcribe(
        audio_path,
        language=language,
        vad_filter=True,
        beam_size=beam_size,
    )
    return "".join([seg.text for seg in segments]).strip()


def worker_loop(model, language, beam_size):
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            audio = req.get("audio")
        except Exception:
            print(json.dumps({"ok": False, "error": "Invalid request"}))
            sys.stdout.flush()
            continue

        if not audio or not os.path.exists(audio):
            print(json.dumps({"ok": False, "error": "Audio file not found"}))
            sys.stdout.flush()
            continue

        try:
            text = transcribe_once(model, audio, language, beam_size)
            print(json.dumps({"ok": True, "text": text}))
        except Exception as e:
            print(json.dumps({"ok": False, "error": str(e)}))
        sys.stdout.flush()


def main():
    args = parse_args()

    if not args.worker:
        if not args.audio or not os.path.exists(args.audio):
            print("Audio file not found", file=sys.stderr)
            return 2

    local_only = not args.allow_download

    device = args.device
    compute_type = resolve_compute_type(device, args.compute_type)

    try:
        model = WhisperModel(
            args.model,
            device=device,
            compute_type=compute_type,
            local_files_only=local_only,
        )
    except Exception as e:
        print(f"Failed to load model: {e}", file=sys.stderr)
        return 3

    if args.worker:
        worker_loop(model, args.language, args.beam_size)
        return 0

    text = transcribe_once(model, args.audio, args.language, args.beam_size)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
