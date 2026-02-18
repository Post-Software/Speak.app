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
  done < <(otool -L "${file}" 2>/dev/null | tail -n +2 | awk '{print $1}')
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

echo "Bundled Python verification passed for: ${APP_PATH}"
