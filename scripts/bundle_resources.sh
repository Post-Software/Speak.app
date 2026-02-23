#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "${SRCROOT}/.." && pwd)"
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
PY_SRC="${ROOT}/python/.venv"
PY_DEST="${RESOURCES}/python"
SCRIPT_SRC="${ROOT}/python/transcribe.py"
ABS_PY_FRAMEWORK_PREFIX="/Library/Frameworks/Python.framework/Versions/"
MODIFIED_MACHOS=()

relpath() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import os
import sys

print(os.path.relpath(sys.argv[2], os.path.dirname(sys.argv[1])))
PY
}

collect_macho_targets() {
  find "${PY_DEST}" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'Python' -o -path '*/bin/python' -o -path '*/bin/python3' -o -path '*/bin/python3.*' \)
}

mark_modified_macho() {
  local macho="$1"
  local existing
  for existing in "${MODIFIED_MACHOS[@]-}"; do
    if [[ "${existing}" == "${macho}" ]]; then
      return
    fi
  done
  MODIFIED_MACHOS+=("${macho}")
}

ad_hoc_sign_modified_machos() {
  local macho
  for macho in "${MODIFIED_MACHOS[@]-}"; do
    [ -z "${macho}" ] && continue
    if ! codesign --force --sign - "${macho}" >/dev/null 2>&1; then
      echo "Failed to ad-hoc sign relinked binary: ${macho}"
      exit 1
    fi
  done
}

verify_signed_modified_machos() {
  local macho
  for macho in "${MODIFIED_MACHOS[@]-}"; do
    [ -z "${macho}" ] && continue
    if ! codesign -dvv "${macho}" >/dev/null 2>&1; then
      echo "Code signature metadata missing for relinked binary: ${macho}"
      exit 1
    fi
  done
}

rewrite_absolute_python_framework_refs() {
  local framework_dest="${PY_DEST}/Python.framework"
  [ -d "${framework_dest}/Versions" ] || return 0

  while IFS= read -r macho; do
    [ -z "${macho}" ] && continue
    deps="$(
      otool -L "${macho}" 2>/dev/null |
      tail -n +2 |
      awk '{print $1}' |
      awk -v p="${ABS_PY_FRAMEWORK_PREFIX}" 'index($0, p) == 1' |
      sort -u || true
    )"
    ids="$(
      otool -D "${macho}" 2>/dev/null |
      tail -n +2 |
      awk -v p="${ABS_PY_FRAMEWORK_PREFIX}" 'index($0, p) == 1' |
      sort -u || true
    )"

    while IFS= read -r old_id; do
      [ -z "${old_id}" ] && continue
      rest="${old_id#${ABS_PY_FRAMEWORK_PREFIX}}"
      version="${rest%%/*}"
      suffix="${rest#*/}"
      target="${framework_dest}/Versions/${version}/${suffix}"
      if [ ! -f "${target}" ]; then
        echo "Missing bundled target for install name '${old_id}' in '${macho}'"
        exit 1
      fi
      rel_target="$(relpath "${macho}" "${target}")"
      install_name_tool -id "@loader_path/${rel_target}" "${macho}" 2>/dev/null
      mark_modified_macho "${macho}"
    done <<< "${ids}"

    while IFS= read -r dep; do
      [ -z "${dep}" ] && continue
      rest="${dep#${ABS_PY_FRAMEWORK_PREFIX}}"
      version="${rest%%/*}"
      suffix="${rest#*/}"
      target="${framework_dest}/Versions/${version}/${suffix}"
      if [ ! -f "${target}" ]; then
        echo "Missing bundled target for dependency '${dep}' referenced by '${macho}'"
        exit 1
      fi
      rel_target="$(relpath "${macho}" "${target}")"
      install_name_tool -change "${dep}" "@loader_path/${rel_target}" "${macho}" 2>/dev/null
      mark_modified_macho "${macho}"
    done <<< "${deps}"
  done < <(collect_macho_targets)
}

ensure_no_absolute_python_framework_refs() {
  unresolved="$(
    while IFS= read -r macho; do
      [ -z "${macho}" ] && continue
      otool -L "${macho}" 2>/dev/null |
      tail -n +2 |
      awk '{print $1}' |
      awk -v p="${ABS_PY_FRAMEWORK_PREFIX}" 'index($0, p) == 1 { print "'"${macho}"' -> " $0 }'
    done < <(collect_macho_targets)
  )"
  if [ -n "${unresolved}" ]; then
    echo "Unresolved absolute Python.framework dependencies after bundling:"
    echo "${unresolved}"
    exit 1
  fi
}

if [ ! -d "${PY_SRC}" ]; then
  echo "Missing venv at ${PY_SRC}. Create it with: python3 -m venv python/.venv"
  exit 1
fi

if [ ! -x "${PY_SRC}/bin/python" ]; then
  echo "Incomplete venv at ${PY_SRC}. Missing bin/python. Reinstall dependencies in python/.venv."
  exit 1
fi

if ! find "${PY_SRC}/lib" -path "*/site-packages/faster_whisper/__init__.py" -print -quit | grep -q .; then
  echo "faster-whisper is missing in ${PY_SRC}. Run: python/.venv/bin/pip install -r python/requirements.txt"
  exit 1
fi

if ! find "${PY_SRC}/lib" -path "*/site-packages/huggingface_hub/__init__.py" -print -quit | grep -q .; then
  echo "huggingface_hub is missing in ${PY_SRC}. Run: python/.venv/bin/pip install -r python/requirements.txt"
  exit 1
fi

mkdir -p "${PY_DEST}"
# -L dereferences symlinks so bundled Python does not depend on build-machine paths.
rsync -aL --delete "${PY_SRC}/" "${PY_DEST}/"
cp "${SCRIPT_SRC}" "${RESOURCES}/python/transcribe.py"
for pybin in "${PY_DEST}/bin/python" "${PY_DEST}/bin/python3" "${PY_DEST}"/bin/python3.*; do
  [ -f "${pybin}" ] && chmod +x "${pybin}" || true
done

# If the venv comes from python.org's framework build, the interpreter links to
# /Library/Frameworks/Python.framework. Bundle that framework and rewrite the
# load command to an app-local path so end users do not need Python installed.
PY3_REAL="$(
  /usr/bin/python3 - "${PY_SRC}/bin/python3" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
if [[ "${PY3_REAL}" == */Python.framework/Versions/*/bin/python3* ]]; then
  PY_VERSION="${PY3_REAL#*/Python.framework/Versions/}"
  PY_VERSION="${PY_VERSION%%/*}"
  FRAMEWORK_SRC="${PY3_REAL%%/Versions/*}"
  FRAMEWORK_DEST="${PY_DEST}/Python.framework"
  FRAMEWORK_VERSION_DEST="${FRAMEWORK_DEST}/Versions/${PY_VERSION}"

  if [ -f "${FRAMEWORK_SRC}/Versions/${PY_VERSION}/Python" ]; then
    mkdir -p "${FRAMEWORK_DEST}"
    rsync -a --delete "${FRAMEWORK_SRC}/" "${FRAMEWORK_DEST}/"
    find "${FRAMEWORK_DEST}" \( -type f -o -type l \) -name "python3*-intel64" -delete || true

    # Trim non-runtime framework payload to keep app size reasonable.
    # The venv already carries app dependencies in ${PY_DEST}/lib/pythonX.Y/site-packages.
    FRAMEWORK_STD_LIB="${FRAMEWORK_VERSION_DEST}/lib/python${PY_VERSION}"
    rm -rf "${FRAMEWORK_STD_LIB}/site-packages" || true
    rm -rf "${FRAMEWORK_STD_LIB}/test" || true
    rm -rf "${FRAMEWORK_STD_LIB}/tkinter/test" || true
    rm -rf "${FRAMEWORK_VERSION_DEST}/Resources/English.lproj/Documentation" || true
    find "${FRAMEWORK_VERSION_DEST}" -type d -name "__pycache__" -prune -exec rm -rf {} + || true
    find "${FRAMEWORK_VERSION_DEST}" -type f -name "*.pyc" -delete || true
    while IFS= read -r -d '' broken_link; do
      rm -f "${broken_link}"
    done < <(find -L "${FRAMEWORK_DEST}" -type l -print0 2>/dev/null || true)

  fi
fi

rewrite_absolute_python_framework_refs
ensure_no_absolute_python_framework_refs
ad_hoc_sign_modified_machos
verify_signed_modified_machos
