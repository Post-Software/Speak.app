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

prune_framework_site_packages() {
  local framework_root="${PY_ROOT}/Python.framework"
  [ -d "${framework_root}" ] || return 0
  find "${framework_root}/Versions" -type d -path "*/lib/python*/site-packages" -prune -exec rm -rf {} + 2>/dev/null || true
  find "${framework_root}/lib" -type d -path "*/python*/site-packages" -prune -exec rm -rf {} + 2>/dev/null || true
}

collect_targets() {
  find "${PY_ROOT}" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'Python' -o -path '*/bin/python' -o -path '*/bin/python3' -o -path '*/bin/python3.*' \)
}

versions="$(
  collect_targets |
  while IFS= read -r file; do
    otool -L "${file}" 2>/dev/null | tail -n +2 | awk '{print $1}'
    otool -D "${file}" 2>/dev/null | tail -n +2
  done |
  awk 'index($0, "/Library/Frameworks/Python.framework/Versions/")==1' |
  while IFS= read -r dep; do
    rest="${dep#*/Versions/}"
    echo "${rest%%/*}"
  done |
  sort -u
)"

if [ -z "${versions}" ]; then
  prune_framework_site_packages
  exit 0
fi

find "${PY_ROOT}/Python.framework" -type f -name "python3*-intel64" -delete || true
prune_framework_site_packages

while IFS= read -r version; do
  [ -z "${version}" ] && continue
  old_prefix="/Library/Frameworks/Python.framework/Versions/${version}"
  framework_version_dest="${PY_ROOT}/Python.framework/Versions/${version}"
  if [ ! -d "${framework_version_dest}" ]; then
    echo "Missing bundled Python.framework version directory: ${framework_version_dest}"
    exit 1
  fi

  while IFS= read -r macho; do
    deps="$(otool -L "${macho}" 2>/dev/null | tail -n +2 | awk -v p="${old_prefix}/" 'index($1,p)==1 {print $1}' | sort -u || true)"
    ids="$(otool -D "${macho}" 2>/dev/null | tail -n +2 | awk -v p="${old_prefix}/" 'index($1,p)==1 {print $1}' | sort -u || true)"
    [ -z "${deps}" ] && [ -z "${ids}" ] && continue

    while IFS= read -r old_id; do
      [ -z "${old_id}" ] && continue
      suffix="${old_id#${old_prefix}/}"
      target="${framework_version_dest}/${suffix}"
      if [ ! -f "${target}" ]; then
        echo "Missing bundled target for install name '${old_id}' in '${macho}'"
        exit 1
      fi
      rel_target="$(
        /usr/bin/python3 - "${macho}" "${target}" <<'PY'
import os
import sys

print(os.path.relpath(sys.argv[2], os.path.dirname(sys.argv[1])))
PY
      )"
      install_name_tool -id "@loader_path/${rel_target}" "${macho}" 2>/dev/null
    done <<< "${ids}"

    while IFS= read -r dep; do
      [ -z "${dep}" ] && continue
      suffix="${dep#${old_prefix}/}"
      target="${framework_version_dest}/${suffix}"
      if [ ! -f "${target}" ]; then
        echo "Missing bundled target for dependency '${dep}' referenced by '${macho}'"
        exit 1
      fi
      rel_target="$(
        /usr/bin/python3 - "${macho}" "${target}" <<'PY'
import os
import sys

print(os.path.relpath(sys.argv[2], os.path.dirname(sys.argv[1])))
PY
      )"
      install_name_tool -change "${dep}" "@loader_path/${rel_target}" "${macho}" 2>/dev/null
    done <<< "${deps}"
  done < <(collect_targets)
done <<< "${versions}"
