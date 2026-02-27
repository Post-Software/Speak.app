#!/usr/bin/env python3
import argparse
import inspect
import json
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import uuid

ENGINE_WHISPER = "whisper"
ENGINE_PARAKEET_TDT_V3 = "parakeet_tdt_v3"
COREML_PROVIDER = "CoreMLExecutionProvider"
CPU_PROVIDER = "CPUExecutionProvider"

PARAKEET_TOKENIZER_CANDIDATES = ("tokenizer.model", "tokenizer.json", "vocab.txt", "tokens.txt")
PARAKEET_CONFIG_CANDIDATES = ("config.yaml", "model_config.yaml", "config.json")

MODEL_SPECS = {
    "parakeet_tdt_0_6b_v3": {
        "repo": "nemo-parakeet-tdt-0.6b-v3",
        "download_url": "https://blob.handy.computer/parakeet-v3-int8.tar.gz",
        "onnx_repo": "istupakov/parakeet-tdt-0.6b-v3-onnx",
        "size_repo": "istupakov/parakeet-tdt-0.6b-v3-onnx",
        "display_name": "Parakeet v3 (Default)",
        "fallback_bytes": 478_000_000,
        "engine": ENGINE_PARAKEET_TDT_V3,
    },
    "whisper_small_en": {
        "repo": "Systran/faster-whisper-small.en",
        "display_name": "Small (Fastest)",
        "fallback_bytes": 500_000_000,
        "engine": ENGINE_WHISPER,
    },
    "whisper_medium_en": {
        "repo": "Systran/faster-whisper-medium.en",
        "display_name": "Medium (Recommended)",
        "fallback_bytes": 1_500_000_000,
        "engine": ENGINE_WHISPER,
    },
    "whisper_large_v3": {
        "repo": "Systran/faster-whisper-large-v3",
        "display_name": "Large v3 (Best Accuracy)",
        "fallback_bytes": 3_000_000_000,
        "engine": ENGINE_WHISPER,
    },
}


def parse_args():
    p = argparse.ArgumentParser(description="Local transcription with Speak engines")
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
    p.add_argument("--runtime-check", action="store_true", help="Print runtime compatibility metadata JSON")
    p.add_argument("--ensure-runtime", action="store_true", help="Install runtime dependencies for model if needed")
    p.add_argument("--verify-model", action="store_true", help="Verify a downloaded model directory")

    p.add_argument("--model-id", required=False, help="Managed model identifier")
    p.add_argument("--dest", required=False, help="Destination root path for managed model operations")
    p.add_argument("--runtime-root", required=False, help="Runtime root path for engine dependency install")
    p.add_argument("--model-path", required=False, help="Path to model directory for verification")

    return p.parse_args()


def resolve_compute_type(device, compute_type):
    if compute_type != "auto":
        return compute_type
    if device == "metal":
        return "float16"
    return "int8"


def require_model_spec(model_id):
    spec = MODEL_SPECS.get(model_id)
    if not spec:
        raise ValueError(f"Unknown model id: {model_id}")
    return spec


def runtime_payload(model_id, supported, status, reason="", requires_install=False):
    return {
        "model_id": model_id,
        "supported": bool(supported),
        "status": status,
        "reason": reason,
        "requires_install": bool(requires_install),
    }


def runtime_site_packages(runtime_root):
    if not runtime_root:
        return ""
    return os.path.join(runtime_root, "parakeet-v3", "site-packages")


def append_runtime_site_packages(runtime_root):
    site_packages = runtime_site_packages(runtime_root)
    if site_packages and os.path.isdir(site_packages) and site_packages not in sys.path:
        sys.path.insert(0, site_packages)
    return site_packages


def import_whisper_model_class():
    try:
        from faster_whisper import WhisperModel as ImportedWhisperModel  # type: ignore
        return ImportedWhisperModel
    except Exception as exc:
        raise RuntimeError(
            "Whisper runtime dependency 'faster-whisper' is missing or broken in the bundled Python runtime."
        ) from exc


def import_hf_client():
    try:
        from huggingface_hub import HfApi as ImportedHfApi, snapshot_download as imported_snapshot_download  # type: ignore
        return ImportedHfApi, imported_snapshot_download
    except Exception as exc:
        raise RuntimeError(
            "Model metadata/download dependency 'huggingface_hub' is missing from the bundled Python runtime."
        ) from exc


def runtime_support_for_model(model_id, runtime_root=None):
    spec = require_model_spec(model_id)
    engine = spec.get("engine")

    if engine == ENGINE_WHISPER:
        return runtime_payload(model_id=model_id, supported=True, status="ok")

    if engine == ENGINE_PARAKEET_TDT_V3:
        return runtime_support_for_parakeet(model_id=model_id, runtime_root=runtime_root)

    return runtime_payload(
        model_id=model_id,
        supported=False,
        status="unsupported",
        reason=f"Unsupported engine: {engine}",
        requires_install=False,
    )


def runtime_support_for_parakeet(model_id, runtime_root=None):
    append_runtime_site_packages(runtime_root)

    onnx_asr, onnxruntime, missing_modules, import_errors = import_onnx_stack()

    if missing_modules:
        missing_list = ", ".join(sorted(missing_modules))
        return runtime_payload(
            model_id=model_id,
            supported=False,
            status="missing_runtime",
            reason=f"Parakeet v3 runtime dependencies are missing ({missing_list}).",
            requires_install=True,
        )

    if import_errors:
        joined = "; ".join(
            f"{name}: {normalize_error_message(exc)}" for name, exc in import_errors
        )
        return runtime_payload(
            model_id=model_id,
            supported=False,
            status="unsupported",
            reason=f"Parakeet v3 runtime could not be initialized ({joined}).",
            requires_install=False,
        )

    try:
        providers = list(onnxruntime.get_available_providers() or [])
    except Exception as exc:
        return runtime_payload(
            model_id=model_id,
            supported=False,
            status="unsupported",
            reason=f"Could not query ONNX Runtime providers ({normalize_error_message(exc)}).",
            requires_install=False,
        )

    if CPU_PROVIDER not in providers:
        provider_list = ", ".join(providers) if providers else "none"
        return runtime_payload(
            model_id=model_id,
            supported=False,
            status="unsupported",
            reason=f"ONNX Runtime CPU provider is unavailable (providers: {provider_list}).",
            requires_install=False,
        )

    return runtime_payload(model_id=model_id, supported=True, status="ok")


def ensure_runtime_for_model(model_id, runtime_root):
    spec = require_model_spec(model_id)
    if spec.get("engine") == ENGINE_WHISPER:
        return {
            "ok": True,
            "model_id": model_id,
            "status": "skipped",
            "reason": "Whisper models use bundled runtime.",
        }

    if not runtime_root:
        raise ValueError("--runtime-root is required for --ensure-runtime")

    first_check = runtime_support_for_model(model_id, runtime_root=runtime_root)
    if first_check.get("supported"):
        return {
            "ok": True,
            "model_id": model_id,
            "status": "ready",
            "installed": False,
            "runtime": first_check,
        }

    if first_check.get("status") == "unsupported":
        raise RuntimeError(first_check.get("reason") or "Runtime is unsupported.")

    if not first_check.get("requires_install"):
        raise RuntimeError(first_check.get("reason") or "Runtime check failed.")

    requirements_path = os.path.join(os.path.dirname(__file__), "requirements-parakeet-v3.txt")
    if not os.path.isfile(requirements_path):
        raise RuntimeError(f"Missing runtime requirements file: {requirements_path}")

    site_packages = runtime_site_packages(runtime_root)
    if not site_packages:
        raise RuntimeError("Could not resolve runtime site-packages path.")

    os.makedirs(site_packages, exist_ok=True)

    install_cmd = [
        sys.executable,
        "-m",
        "pip",
        "install",
        "--upgrade",
        "--target",
        site_packages,
        "-r",
        requirements_path,
    ]

    proc = subprocess.run(install_cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip()
        stdout = (proc.stdout or "").strip()
        summary_source = stderr if stderr else stdout
        summary_lines = [line.strip() for line in summary_source.splitlines() if line.strip()]
        if summary_lines:
            summary = " | ".join(summary_lines[-3:])
        else:
            summary = "pip install failed without output."
        if len(summary) > 350:
            summary = summary[:350] + "…"
        raise RuntimeError(f"Failed to install Parakeet runtime dependencies. {summary}")

    append_runtime_site_packages(runtime_root)

    second_check = runtime_support_for_model(model_id, runtime_root=runtime_root)
    if not second_check.get("supported"):
        raise RuntimeError(second_check.get("reason") or "Runtime is still not ready after installation.")

    return {
        "ok": True,
        "model_id": model_id,
        "status": "ready",
        "installed": True,
        "site_packages": site_packages,
        "runtime": second_check,
    }


def compute_repo_size(repo_id):
    hf_api_cls, _ = import_hf_client()
    api = hf_api_cls()
    info = api.model_info(repo_id=repo_id, files_metadata=True)

    total = 0
    for sibling in info.siblings or []:
        size = getattr(sibling, "size", None)
        if isinstance(size, int):
            total += size

    if total > 0:
        return total

    for entry in api.list_repo_tree(repo_id=repo_id, recursive=True):
        if getattr(entry, "type", None) != "file":
            continue
        size = getattr(entry, "size", None)
        if isinstance(size, int):
            total += size

    return total


def compute_url_size(url):
    request = urllib.request.Request(url=url, method="HEAD")
    with urllib.request.urlopen(request, timeout=30) as response:
        content_length = response.headers.get("Content-Length")
        if content_length and content_length.isdigit():
            return int(content_length)
    return 0


def normalize_error_message(exc):
    message = str(exc).strip()
    if not message:
        return "Unknown error"

    if "nodename nor servname provided" in message:
        return "Could not connect to Hugging Face. Check your internet connection."

    if "status code 400" in message and "/api/models/" in message:
        return "Model metadata API request failed (400). Please update Speak or try again later."

    if "Please check your internet connection and try again." in message:
        return "Could not download model from Hugging Face. Check your internet connection and try again."

    if "No module named" in message:
        return f"Missing Python dependency: {message}"

    if len(message) > 280:
        return f"{message[:280]}…"
    return message


def verify_whisper_model_dir(model_path):
    required = ["model.bin", "config.json", "tokenizer.json"]
    for name in required:
        candidate = os.path.join(model_path, name)
        if not os.path.exists(candidate):
            raise ValueError(f"Downloaded model is incomplete (missing {name}).")


def verify_parakeet_model_dir(model_path):
    if not os.path.isdir(model_path):
        raise ValueError("Downloaded model directory is missing.")

    if has_handy_parakeet_layout(model_path):
        return

    # Canonical onnx-asr layout.
    if not has_onnx_artifact(model_path):
        raise ValueError(
            "Downloaded Parakeet model is incomplete (missing ONNX model artifact)."
        )

    if not has_tokenizer_artifact(model_path):
        raise ValueError(
            "Downloaded Parakeet model is incomplete (missing tokenizer artifact)."
        )

    if not has_config_artifact(model_path):
        raise ValueError(
            "Downloaded Parakeet model is incomplete (missing config artifact)."
        )


def parakeet_model_files_present(path):
    if not os.path.isdir(path):
        return False
    if has_handy_parakeet_layout(path):
        return True
    return (
        has_onnx_artifact(path)
        and has_tokenizer_artifact(path)
        and has_config_artifact(path)
    )


def has_handy_parakeet_layout(path):
    lower_names = [name.lower() for name in os.listdir(path)]
    has_nemo = any(name == "nemo128.onnx" or (name.startswith("nemo") and name.endswith(".onnx")) for name in lower_names)
    has_encoder = any(name.startswith("encoder-model") and name.endswith(".onnx") for name in lower_names)
    has_decoder = any(name.startswith("decoder_joint-model") and name.endswith(".onnx") for name in lower_names)
    has_vocab = any(name == "vocab.txt" or ("vocab" in name and name.endswith(".txt")) for name in lower_names)
    return has_nemo and has_encoder and has_decoder and has_vocab


def has_onnx_artifact(path):
    for name in os.listdir(path):
        if name.lower().endswith(".onnx"):
            return True
    return False


def has_tokenizer_artifact(path):
    lower_names = [name.lower() for name in os.listdir(path)]
    for candidate in PARAKEET_TOKENIZER_CANDIDATES:
        if candidate in lower_names:
            return True

    for name in lower_names:
        if name.startswith("tokenizer.") or name.startswith("tokenizer_"):
            return True
        if "tokenizer" in name and (name.endswith(".json") or name.endswith(".model")):
            return True
        if "vocab" in name and name.endswith(".txt"):
            return True
        if "tokens" in name and (name.endswith(".txt") or name.endswith(".json")):
            return True
    return False


def has_config_artifact(path):
    lower_names = [name.lower() for name in os.listdir(path)]
    for candidate in PARAKEET_CONFIG_CANDIDATES:
        if candidate in lower_names:
            return True

    for name in lower_names:
        if "config" in name and (name.endswith(".yaml") or name.endswith(".yml") or name.endswith(".json")):
            return True
    return False


def locate_parakeet_model_dir(root):
    if parakeet_model_files_present(root):
        return root

    for current_root, _, _ in os.walk(root):
        if current_root == root:
            continue
        if parakeet_model_files_present(current_root):
            return current_root

    raise RuntimeError(
        "Could not locate downloaded Parakeet ONNX artifacts (expected Handy layout or onnx-asr layout)."
    )


def import_onnx_stack():
    missing_modules = []
    import_errors = []

    onnx_asr = None
    onnxruntime = None

    try:
        import onnx_asr as imported_onnx_asr  # type: ignore
        onnx_asr = imported_onnx_asr
    except ModuleNotFoundError:
        missing_modules.append("onnx-asr")
    except Exception as exc:
        import_errors.append(("onnx-asr", exc))

    try:
        import onnxruntime as imported_onnxruntime  # type: ignore
        onnxruntime = imported_onnxruntime
    except ModuleNotFoundError:
        missing_modules.append("onnxruntime")
    except Exception as exc:
        import_errors.append(("onnxruntime", exc))

    return onnx_asr, onnxruntime, missing_modules, import_errors


def call_onnx_load_model(onnx_asr, model_name, model_path=None, provider=None):
    load_model = getattr(onnx_asr, "load_model", None)
    if load_model is None:
        raise RuntimeError("onnx-asr does not expose load_model().")

    kwargs_variants = []

    signature = None
    try:
        signature = inspect.signature(load_model)
    except Exception:
        signature = None

    if signature is not None:
        params = signature.parameters
        kwargs = {}

        if model_path:
            for key in ("path", "model_path", "cache_dir"):
                if key in params:
                    kwargs[key] = model_path
                    break

        if provider:
            for key in ("provider", "execution_provider"):
                if key in params:
                    kwargs[key] = provider
                    break

        kwargs_variants.append(kwargs)

    if model_path:
        kwargs_variants.append({"path": model_path, "provider": provider} if provider else {"path": model_path})
        kwargs_variants.append({"model_path": model_path, "provider": provider} if provider else {"model_path": model_path})
        kwargs_variants.append({"cache_dir": model_path, "provider": provider} if provider else {"cache_dir": model_path})
    elif provider:
        kwargs_variants.append({"provider": provider})

    errors = []
    seen_kwargs = set()
    for kwargs in kwargs_variants:
        cleaned = {k: v for k, v in kwargs.items() if v is not None}
        key = tuple(sorted(cleaned.items()))
        if key in seen_kwargs:
            continue
        seen_kwargs.add(key)
        try:
            return load_model(model_name, **cleaned)
        except TypeError as exc:
            errors.append(normalize_error_message(exc))
            continue

    positional_attempts = []
    if model_path and provider:
        positional_attempts.append((model_name, model_path, provider))
        positional_attempts.append((model_name, provider, model_path))
    if model_path:
        positional_attempts.append((model_name, model_path))
    if provider:
        positional_attempts.append((model_name, provider))
    positional_attempts.append((model_name,))

    for args in positional_attempts:
        try:
            return load_model(*args)
        except TypeError as exc:
            errors.append(normalize_error_message(exc))
            continue

    summary = "; ".join(errors[-3:])
    raise RuntimeError(f"Could not call onnx-asr load_model API. {summary}")


def download_file(url, output_path):
    with urllib.request.urlopen(url, timeout=120) as response:
        with open(output_path, "wb") as f:
            shutil.copyfileobj(response, f)


def extract_tarball(archive_path, destination):
    with tarfile.open(archive_path, "r:*") as tar:
        tar.extractall(destination)


def download_parakeet_model(spec, staging_dir):
    os.makedirs(staging_dir, exist_ok=True)
    errors = []

    download_url = spec.get("download_url")
    if download_url:
        archive_path = os.path.join(staging_dir, "parakeet-v3-int8.tar.gz")
        try:
            download_file(download_url, archive_path)
            extract_tarball(archive_path, staging_dir)
            if os.path.exists(archive_path):
                os.remove(archive_path)

            artifact_dir = locate_parakeet_model_dir(staging_dir)
            verify_parakeet_model_dir(artifact_dir)
            return artifact_dir
        except Exception as exc:
            errors.append(f"Handy blob download failed: {normalize_error_message(exc)}")
            try:
                if os.path.exists(archive_path):
                    os.remove(archive_path)
            except Exception:
                pass

    try:
        _, snapshot_download = import_hf_client()
        repo_id = spec.get("onnx_repo") or spec.get("size_repo") or spec["repo"]
        snapshot_download(
            repo_id=repo_id,
            local_dir=staging_dir,
        )
        artifact_dir = locate_parakeet_model_dir(staging_dir)
        verify_parakeet_model_dir(artifact_dir)
        return artifact_dir
    except Exception as exc:
        errors.append(f"Hugging Face ONNX download failed: {normalize_error_message(exc)}")

    raise RuntimeError(" ; ".join(errors) if errors else "Failed to download Parakeet model.")


def verify_model_dir(model_id, model_path):
    spec = require_model_spec(model_id)
    if not model_path:
        raise ValueError("Model path is missing.")

    if spec.get("engine") == ENGINE_WHISPER:
        verify_whisper_model_dir(model_path)
    elif spec.get("engine") == ENGINE_PARAKEET_TDT_V3:
        verify_parakeet_model_dir(model_path)
    else:
        raise ValueError(f"Unsupported engine for model verification: {spec.get('engine')}")


def handle_model_info(args):
    if not args.model_id:
        raise ValueError("--model-id is required for --model-info")

    spec = require_model_spec(args.model_id)
    total_bytes = int(spec.get("fallback_bytes", 0))
    size_source = "fallback"

    try:
        computed = 0
        download_url = spec.get("download_url")
        if download_url:
            computed = compute_url_size(download_url)

        if not computed:
            size_repo = spec.get("size_repo", spec["repo"])
            computed = compute_repo_size(size_repo)

        if isinstance(computed, int) and computed > 0:
            total_bytes = computed
            size_source = "exact"
    except Exception as exc:
        # Keep setup flow usable even when metadata lookup is temporarily failing.
        print(
            f"Model info warning ({args.model_id}): {normalize_error_message(exc)}",
            file=sys.stderr,
        )

    payload = {
        "id": args.model_id,
        "repo": spec["repo"],
        "display_name": spec["display_name"],
        "download_bytes": int(total_bytes),
        "size_source": size_source,
    }
    print(json.dumps(payload))
    return 0


def handle_runtime_check(args):
    if not args.model_id:
        raise ValueError("--model-id is required for --runtime-check")

    payload = runtime_support_for_model(args.model_id, runtime_root=args.runtime_root)
    print(json.dumps(payload))
    return 0


def handle_ensure_runtime(args):
    if not args.model_id:
        raise ValueError("--model-id is required for --ensure-runtime")
    if not args.runtime_root:
        raise ValueError("--runtime-root is required for --ensure-runtime")

    payload = ensure_runtime_for_model(args.model_id, args.runtime_root)
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

    source_dir = staging_dir

    try:
        if spec.get("engine") == ENGINE_PARAKEET_TDT_V3:
            source_dir = download_parakeet_model(spec, staging_dir)
        else:
            _, snapshot_download = import_hf_client()
            snapshot_download(
                repo_id=spec["repo"],
                local_dir=staging_dir,
            )

        if os.path.isdir(target_dir):
            shutil.rmtree(target_dir)

        if os.path.abspath(source_dir) == os.path.abspath(staging_dir):
            os.rename(staging_dir, target_dir)
        else:
            shutil.move(source_dir, target_dir)
            shutil.rmtree(staging_dir, ignore_errors=True)
    except Exception:
        if os.path.isdir(staging_dir):
            shutil.rmtree(staging_dir, ignore_errors=True)
        raise

    print(json.dumps({"ok": True, "path": target_dir}))
    return 0


def handle_verify_model(args):
    if not args.model_id:
        raise ValueError("--model-id is required for --verify-model")
    if not args.model_path:
        raise ValueError("--model-path is required for --verify-model")

    verify_model_dir(args.model_id, args.model_path)
    print(json.dumps({"ok": True, "path": args.model_path}))
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


class WhisperBackend:
    def __init__(self, model_path, language, beam_size, device, compute_type, local_only):
        self.language = language
        self.beam_size = beam_size
        whisper_model_cls = import_whisper_model_class()
        self.model = whisper_model_cls(
            model_path,
            device=device,
            compute_type=compute_type,
            local_files_only=local_only,
        )

    def transcribe(self, audio_path):
        segments, _ = self.model.transcribe(
            audio_path,
            language=self.language,
            vad_filter=True,
            beam_size=self.beam_size,
        )
        return "".join([seg.text for seg in segments]).strip()


class ParakeetBackend:
    def __init__(self, model_id, model_path, local_only, runtime_root=None):
        self.model_id = model_id
        self.model_path = model_path
        self.local_only = local_only
        self.runtime_root = runtime_root
        self.active_provider = ""

        append_runtime_site_packages(runtime_root)

        onnx_asr, onnxruntime, missing_modules, import_errors = import_onnx_stack()
        if missing_modules:
            missing_list = ", ".join(sorted(missing_modules))
            raise RuntimeError(
                "Parakeet runtime is missing. Re-run setup to install dependencies "
                f"({missing_list})."
            )
        if import_errors:
            joined = "; ".join(
                f"{name}: {normalize_error_message(exc)}" for name, exc in import_errors
            )
            raise RuntimeError(f"Parakeet runtime could not be initialized ({joined}).")

        self.onnx_asr = onnx_asr
        self.onnxruntime = onnxruntime
        self.providers = list(onnxruntime.get_available_providers() or [])

        if CPU_PROVIDER not in self.providers:
            provider_list = ", ".join(self.providers) if self.providers else "none"
            raise RuntimeError(
                f"Parakeet v3 requires ONNX CPU provider; available providers: {provider_list}."
            )

        if self.local_only and not os.path.isdir(self.model_path):
            raise RuntimeError("Parakeet model is not available locally.")

        if os.path.isdir(self.model_path):
            verify_parakeet_model_dir(self.model_path)

        preferred_order = []
        if COREML_PROVIDER in self.providers:
            preferred_order.append(COREML_PROVIDER)
        preferred_order.append(CPU_PROVIDER)
        self.model, self.active_provider = self._load_model(preferred_order)

    def _load_model(self, provider_order):
        spec = require_model_spec(self.model_id)
        errors = []
        model_name = spec["repo"]
        model_path = self.model_path if os.path.isdir(self.model_path) else None

        for provider in provider_order:
            if provider not in self.providers:
                continue
            try:
                model = call_onnx_load_model(
                    onnx_asr=self.onnx_asr,
                    model_name=model_name,
                    model_path=model_path,
                    provider=provider,
                )
                return model, provider
            except Exception as exc:
                errors.append(f"{provider}: {normalize_error_message(exc)}")

        joined = "; ".join(errors[-3:]) if errors else "No usable ONNX provider."
        raise RuntimeError(f"Failed to initialize Parakeet v3 backend. {joined}")

    def _infer_once(self, audio_path):
        if hasattr(self.model, "transcribe"):
            transcribe_fn = getattr(self.model, "transcribe")
            try:
                return transcribe_fn(audio_path)
            except TypeError:
                return transcribe_fn([audio_path])

        if callable(self.model):
            try:
                return self.model(audio_path)
            except TypeError:
                return self.model([audio_path])

        raise RuntimeError("Loaded Parakeet model object does not expose a transcribe API.")

    def _extract_text(self, value):
        if value is None:
            return ""

        if isinstance(value, str):
            return value.strip()

        if isinstance(value, (list, tuple)):
            parts = [self._extract_text(item) for item in value]
            return " ".join(part for part in parts if part).strip()

        if isinstance(value, dict):
            for key in ("text", "pred_text", "transcript", "sentence", "sentences"):
                if key in value:
                    return self._extract_text(value.get(key))
            return ""

        for attr in ("text", "pred_text", "transcript"):
            if hasattr(value, attr):
                return self._extract_text(getattr(value, attr))

        return str(value).strip()

    def transcribe(self, audio_path):
        try:
            result = self._infer_once(audio_path)
            return self._extract_text(result)
        except Exception as first_error:
            if self.active_provider == CPU_PROVIDER:
                raise RuntimeError(
                    "Parakeet v3 inference failed on CPU provider: "
                    + normalize_error_message(first_error)
                ) from first_error

            try:
                self.model, self.active_provider = self._load_model([CPU_PROVIDER])
                retry_result = self._infer_once(audio_path)
                return self._extract_text(retry_result)
            except Exception as cpu_error:
                raise RuntimeError(
                    "Parakeet v3 inference failed with CoreML and CPU providers. "
                    f"CoreML error: {normalize_error_message(first_error)}; "
                    f"CPU error: {normalize_error_message(cpu_error)}"
                ) from cpu_error


def build_backend(args):
    if not args.model_id:
        raise ValueError("--model-id is required for transcription worker mode")

    spec = require_model_spec(args.model_id)
    engine = spec.get("engine")
    local_only = not args.allow_download

    if engine == ENGINE_WHISPER:
        device = args.device
        compute_type = resolve_compute_type(device, args.compute_type)
        return WhisperBackend(
            model_path=args.model,
            language=args.language,
            beam_size=args.beam_size,
            device=device,
            compute_type=compute_type,
            local_only=local_only,
        )

    if engine == ENGINE_PARAKEET_TDT_V3:
        runtime = runtime_support_for_model(args.model_id, runtime_root=args.runtime_root)
        if not runtime.get("supported"):
            reason = runtime.get("reason") or "Parakeet v3 runtime is not supported on this machine."
            raise RuntimeError(reason)
        return ParakeetBackend(
            model_id=args.model_id,
            model_path=args.model,
            local_only=local_only,
            runtime_root=args.runtime_root,
        )

    raise RuntimeError(f"Unsupported model engine: {engine}")


def worker_loop(backend):
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
            text = backend.transcribe(audio)
            print(json.dumps({"ok": True, "text": text}))
        except Exception as exc:
            print(json.dumps({"ok": False, "error": normalize_error_message(exc)}))
        sys.stdout.flush()


def main():
    args = parse_args()

    try:
        if args.model_info:
            return handle_model_info(args)
        if args.runtime_check:
            return handle_runtime_check(args)
        if args.ensure_runtime:
            return handle_ensure_runtime(args)
        if args.download_model:
            return handle_download_model(args)
        if args.verify_model:
            return handle_verify_model(args)
        if args.delete_model:
            return handle_delete_model(args)
    except Exception as exc:
        print(normalize_error_message(exc), file=sys.stderr)
        return 4

    if args.worker and not args.model_id:
        print("--model-id is required for --worker", file=sys.stderr)
        return 2

    if not args.worker:
        if not args.audio or not os.path.exists(args.audio):
            print("Audio file not found", file=sys.stderr)
            return 2

    try:
        backend = build_backend(args)
    except Exception as exc:
        print(f"Failed to load model: {normalize_error_message(exc)}", file=sys.stderr)
        return 3

    if args.worker:
        worker_loop(backend)
        return 0

    text = backend.transcribe(args.audio)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
