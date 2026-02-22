#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import sys
import uuid

from faster_whisper import WhisperModel
from huggingface_hub import HfApi, snapshot_download


MODEL_SPECS = {
    "whisper_small_en": {
        "repo": "Systran/faster-whisper-small.en",
        "display_name": "Small (Fastest)",
    },
    "whisper_medium_en": {
        "repo": "Systran/faster-whisper-medium.en",
        "display_name": "Medium (Recommended)",
    },
    "whisper_large_v3": {
        "repo": "Systran/faster-whisper-large-v3",
        "display_name": "Large v3 (Best Accuracy)",
    },
}


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

    p.add_argument("--model-info", action="store_true", help="Print model metadata JSON")
    p.add_argument("--download-model", action="store_true", help="Download a model into destination directory")
    p.add_argument("--delete-model", action="store_true", help="Delete a model directory under destination")
    p.add_argument("--model-id", required=False, help="Managed model identifier")
    p.add_argument("--dest", required=False, help="Destination root path for managed model operations")

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


def require_model_spec(model_id):
    spec = MODEL_SPECS.get(model_id)
    if not spec:
        raise ValueError(f"Unknown model id: {model_id}")
    return spec


def compute_repo_size(repo_id):
    api = HfApi()
    info = api.model_info(repo_id=repo_id, files_metadata=True)

    total = 0
    for sibling in info.siblings or []:
        size = getattr(sibling, "size", None)
        if isinstance(size, int):
            total += size

    if total > 0:
        return total

    for entry in api.list_repo_tree(repo_id=repo_id, recursive=True, expand=True):
        if getattr(entry, "type", None) != "file":
            continue
        size = getattr(entry, "size", None)
        if isinstance(size, int):
            total += size

    return total


def handle_model_info(args):
    if not args.model_id:
        raise ValueError("--model-id is required for --model-info")

    spec = require_model_spec(args.model_id)
    total_bytes = compute_repo_size(spec["repo"])

    payload = {
        "id": args.model_id,
        "repo": spec["repo"],
        "display_name": spec["display_name"],
        "download_bytes": int(total_bytes),
    }
    print(json.dumps(payload))
    return 0


def handle_download_model(args):
    if not args.model_id:
        raise ValueError("--model-id is required for --download-model")
    if not args.dest:
        raise ValueError("--dest is required for --download-model")

    spec = require_model_spec(args.model_id)

    os.makedirs(args.dest, exist_ok=True)
    target_dir = os.path.join(args.dest, args.model_id)
    staging_dir = os.path.join(args.dest, f".staging-{args.model_id}-{uuid.uuid4().hex}")

    if os.path.isdir(staging_dir):
        shutil.rmtree(staging_dir)

    try:
        snapshot_download(
            repo_id=spec["repo"],
            local_dir=staging_dir,
            local_dir_use_symlinks=False,
        )

        if os.path.isdir(target_dir):
            shutil.rmtree(target_dir)
        os.rename(staging_dir, target_dir)
    except Exception:
        if os.path.isdir(staging_dir):
            shutil.rmtree(staging_dir, ignore_errors=True)
        raise

    print(json.dumps({"ok": True, "path": target_dir}))
    return 0


def handle_delete_model(args):
    if not args.model_id:
        raise ValueError("--model-id is required for --delete-model")
    if not args.dest:
        raise ValueError("--dest is required for --delete-model")

    target_dir = os.path.join(args.dest, args.model_id)
    if os.path.isdir(target_dir):
        shutil.rmtree(target_dir)

    print(json.dumps({"ok": True, "path": target_dir}))
    return 0


def main():
    args = parse_args()

    try:
        if args.model_info:
            return handle_model_info(args)
        if args.download_model:
            return handle_download_model(args)
        if args.delete_model:
            return handle_delete_model(args)
    except Exception as e:
        print(str(e), file=sys.stderr)
        return 4

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
