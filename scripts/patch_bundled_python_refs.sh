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
  find "${framework_root}" \( -type f -o -type l \) -name "python3*-intel64" -delete || true
  find "${framework_root}/Versions" -type d -path "*/lib/python*/site-packages" -prune -exec rm -rf {} + 2>/dev/null || true
  find "${framework_root}/lib" -type d -path "*/python*/site-packages" -prune -exec rm -rf {} + 2>/dev/null || true
  while IFS= read -r -d '' broken_link; do
    rm -f "${broken_link}"
  done < <(find -L "${framework_root}" -type l -print0 2>/dev/null || true)
}

collect_targets() {
  find "${PY_ROOT}" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'Python' -o -path '*/bin/python' -o -path '*/bin/python3' -o -path '*/bin/python3.*' \)
}

otool_deps() {
  local macho="$1"
  otool -L "${macho}" 2>/dev/null |
    sed -E -n 's/^[[:space:]]+(.+)[[:space:]]+\(compatibility version.*$/\1/p'
}

otool_ids() {
  local macho="$1"
  otool -D "${macho}" 2>/dev/null |
    awk 'NF && $0 !~ /:$/ {sub(/^[[:space:]]+/, ""); print}'
}

framework_prefixes="$(
  collect_targets |
  while IFS= read -r file; do
    otool_deps "${file}"
    otool_ids "${file}"
  done |
  awk 'index($0, "/Python.framework/Versions/") > 0 && index($0, "/") == 1' |
  sed -E 's#^(.*/Python\.framework/Versions/[^/]+)(/.*)?$#\1#' |
  sort -u
)"

if [ -z "${framework_prefixes}" ]; then
  prune_framework_site_packages
  exit 0
fi

prune_framework_site_packages

while IFS= read -r old_prefix; do
  [ -z "${old_prefix}" ] && continue
  version="${old_prefix##*/Versions/}"
  framework_version_dest="${PY_ROOT}/Python.framework/Versions/${version}"
  if [ ! -d "${framework_version_dest}" ]; then
    echo "Missing bundled Python.framework version directory: ${framework_version_dest}"
    exit 1
  fi

  while IFS= read -r macho; do
    deps="$(otool_deps "${macho}" | awk -v p="${old_prefix}/" 'index($0,p)==1 {print $0}' | sort -u || true)"
    ids="$(otool_ids "${macho}" | awk -v p="${old_prefix}/" 'index($0,p)==1 {print $0}' | sort -u || true)"
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
done <<< "${framework_prefixes}"
