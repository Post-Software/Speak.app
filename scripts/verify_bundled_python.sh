#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
if [ -z "${APP_PATH}" ] || [ ! -d "${APP_PATH}" ]; then
  echo "Usage: $0 /path/to/Speak.app"
  exit 1
fi

PY_ROOT="${APP_PATH}/Contents/Resources/python"
if [ ! -d "${PY_ROOT}" ]; then
  echo "Missing bundled Python directory: ${PY_ROOT}"
  exit 1
fi

collect_targets() {
  find "${PY_ROOT}" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'Python' -o -path '*/bin/python' -o -path '*/bin/python3' -o -path '*/bin/python3.*' \)
}

otool_deps() {
  local macho="$1"
  otool -L "${macho}" 2>/dev/null |
    sed -E -n 's/^[[:space:]]+(.+)[[:space:]]+\(compatibility version.*$/\1/p'
}

resolve_bundled_pythonhome() {
  local versions_dir="${PY_ROOT}/Python.framework/Versions"
  [ -d "${versions_dir}" ] || return 1

  local current_link="${versions_dir}/Current"
  if [ -L "${current_link}" ]; then
    local target
    target="$(readlink "${current_link}" || true)"
    if [ -n "${target}" ]; then
      local candidate
      if [[ "${target}" == /* ]]; then
        candidate="${target}"
      else
        candidate="${versions_dir}/${target}"
      fi
      if [ -d "${candidate}" ]; then
        echo "${candidate}"
        return 0
      fi
    fi
  elif [ -d "${current_link}" ]; then
    echo "${current_link}"
    return 0
  fi

  find "${versions_dir}" -mindepth 1 -maxdepth 1 -type d ! -name Current | sort | head -n 1
}

run_bundled_python() {
  local python_bin="$1"
  shift
  if [ -n "${PYTHONHOME_VALUE:-}" ]; then
    PYTHONHOME="${PYTHONHOME_VALUE}" PYTHONUNBUFFERED=1 PYTHONNOUSERSITE=1 "${python_bin}" "$@"
  else
    PYTHONUNBUFFERED=1 PYTHONNOUSERSITE=1 "${python_bin}" "$@"
  fi
}

missing_arm64=""
while IFS= read -r file; do
  [ -z "${file}" ] && continue
  desc="$(file "${file}")"
  if [[ "${desc}" == *"Mach-O"* ]] && [[ "${desc}" != *"arm64"* ]]; then
    missing_arm64+="${file}"$'\n'
  fi
done < <(collect_targets)
if [ -n "${missing_arm64}" ]; then
  echo "Found non-Apple-Silicon Mach-O files in bundled runtime:"
  echo "${missing_arm64}" | sed -n '1,120p'
  exit 1
fi

abs_framework_refs=""
abs_local_refs=""
while IFS= read -r file; do
  [ -z "${file}" ] && continue
  while IFS= read -r dep; do
    [ -z "${dep}" ] && continue
    case "${dep}" in
      /Library/Frameworks/Python.framework/*)
        abs_framework_refs+="${file} -> ${dep}"$'\n'
        ;;
      /opt/homebrew/*|/usr/local/*|/Users/*)
        abs_local_refs+="${file} -> ${dep}"$'\n'
        ;;
    esac
  done < <(otool_deps "${file}")
done < <(collect_targets)

if [ -n "${abs_framework_refs}" ]; then
  echo "Found unresolved absolute Python.framework references:"
  echo "${abs_framework_refs}" | sed -n '1,120p'
  exit 1
fi

if [ -n "${abs_local_refs}" ]; then
  echo "Found unresolved machine-local absolute references:"
  echo "${abs_local_refs}" | sed -n '1,120p'
  exit 1
fi

PYTHON_BIN=""
for candidate in "${PY_ROOT}/bin/python3" "${PY_ROOT}/bin/python"; do
  if [ -x "${candidate}" ]; then
    PYTHON_BIN="${candidate}"
    break
  fi
done
if [ -z "${PYTHON_BIN}" ]; then
  echo "Missing bundled Python executable under ${PY_ROOT}/bin"
  exit 1
fi

PYTHONHOME_VALUE="$(resolve_bundled_pythonhome || true)"
if [ -z "${PYTHONHOME_VALUE}" ]; then
  echo "Missing bundled Python.framework version directory under ${PY_ROOT}/Python.framework/Versions"
  exit 1
fi

SMOKE_OUTPUT=""
if ! SMOKE_OUTPUT="$(run_bundled_python "${PYTHON_BIN}" -c "import decimal, math; print('python_smoke_ok')" 2>&1)"; then
  echo "Bundled Python smoke test failed (decimal/math import):"
  echo "${SMOKE_OUTPUT}" | sed -n '1,200p'
  exit 1
fi

TRANSCRIBE_SCRIPT="${PY_ROOT}/transcribe.py"
if [ ! -f "${TRANSCRIBE_SCRIPT}" ]; then
  echo "Missing bundled transcription script: ${TRANSCRIBE_SCRIPT}"
  exit 1
fi

PARAKEET_REQ_FILE="${PY_ROOT}/requirements-parakeet-v3.txt"
if [ ! -f "${PARAKEET_REQ_FILE}" ]; then
  echo "Missing bundled Parakeet runtime requirements file: ${PARAKEET_REQ_FILE}"
  exit 1
fi

PARAKEET_WORKER="${APP_PATH}/Contents/Resources/parakeet-worker"
if [ ! -x "${PARAKEET_WORKER}" ]; then
  echo "Missing bundled Parakeet worker executable: ${PARAKEET_WORKER}"
  exit 1
fi

RUNTIME_CHECK_LOG="$(mktemp /tmp/speak-parakeet-runtime.XXXXXX)"
if ! "${PARAKEET_WORKER}" --runtime-check --model-id parakeet_tdt_0_6b_v3 > "${RUNTIME_CHECK_LOG}" 2>&1; then
  echo "Bundled Parakeet worker runtime-check failed:"
  cat "${RUNTIME_CHECK_LOG}" | sed -n '1,200p'
  rm -f "${RUNTIME_CHECK_LOG}"
  exit 1
fi

if ! /usr/bin/python3 - "${RUNTIME_CHECK_LOG}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    lines = [line.strip() for line in f if line.strip()]

for line in reversed(lines):
    try:
        payload = json.loads(line)
    except Exception:
        continue
    if payload.get("model_id") == "parakeet_tdt_0_6b_v3" and "supported" in payload and "status" in payload:
        raise SystemExit(0)

raise SystemExit(1)
PY
then
  echo "Bundled Parakeet worker runtime-check did not produce expected JSON payload:"
  cat "${RUNTIME_CHECK_LOG}" | sed -n '1,200p'
  rm -f "${RUNTIME_CHECK_LOG}"
  exit 1
fi
rm -f "${RUNTIME_CHECK_LOG}"

MODEL_INFO_LOG="$(mktemp /tmp/speak-model-info.XXXXXX)"
if ! run_bundled_python "${PYTHON_BIN}" "${TRANSCRIBE_SCRIPT}" --model-info --model-id whisper_medium_en > "${MODEL_INFO_LOG}" 2>&1; then
  echo "Bundled model-info command failed:"
  cat "${MODEL_INFO_LOG}" | sed -n '1,200p'
  rm -f "${MODEL_INFO_LOG}"
  exit 1
fi

if ! /usr/bin/python3 - "${MODEL_INFO_LOG}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    lines = [line.strip() for line in f if line.strip()]

for line in reversed(lines):
    try:
        payload = json.loads(line)
    except Exception:
        continue
    if payload.get("id") == "whisper_medium_en" and "download_bytes" in payload:
        raise SystemExit(0)

raise SystemExit(1)
PY
then
  echo "Bundled model-info output did not include expected JSON payload:"
  cat "${MODEL_INFO_LOG}" | sed -n '1,200p'
  rm -f "${MODEL_INFO_LOG}"
  exit 1
fi
rm -f "${MODEL_INFO_LOG}"

if [ -d "${APP_PATH}/Contents/Resources/models" ]; then
  echo "Model weights should not be bundled in app resources. Found: ${APP_PATH}/Contents/Resources/models"
  exit 1
fi

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
if [ ! -f "${INFO_PLIST}" ]; then
  echo "Missing app Info.plist: ${INFO_PLIST}"
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "${INFO_PLIST}" >/dev/null 2>&1; then
  echo "Missing NSMicrophoneUsageDescription in app Info.plist"
  exit 1
fi

APP_BINARY="${APP_PATH}/Contents/MacOS/Speak"
if [ -f "${APP_BINARY}" ]; then
  ENT_TMP="$(mktemp /tmp/speak-entitlements.XXXXXX)"
  if /usr/bin/codesign -d --entitlements :- "${APP_BINARY}" 2>/dev/null > "${ENT_TMP}"; then
    if ! grep -q "<key>com.apple.security.device.audio-input</key>" "${ENT_TMP}"; then
      echo "Missing com.apple.security.device.audio-input entitlement on ${APP_BINARY}"
      rm -f "${ENT_TMP}"
      exit 1
    fi
  fi
  rm -f "${ENT_TMP}"
fi

echo "Bundled Python verification passed for: ${APP_PATH}"
echo "Verified no bundled model weights in app resources."
