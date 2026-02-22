#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "${SRCROOT}/.." && pwd)"
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
PY_SRC="${ROOT}/python/.venv"
PY_DEST="${RESOURCES}/python"
MODEL_SRC="${ROOT}/models/medium"
MODEL_DEST="${RESOURCES}/models/medium"
SCRIPT_SRC="${ROOT}/python/transcribe.py"

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

if [ ! -d "${MODEL_SRC}" ]; then
  echo "Missing model at ${MODEL_SRC}. Download Systran/faster-whisper-medium to models/medium"
  exit 1
fi

mkdir -p "${PY_DEST}" "${MODEL_DEST}"
# -L dereferences symlinks so the bundled Python does not depend on absolute paths from the build machine.
rsync -aL --delete "${PY_SRC}/" "${PY_DEST}/"
cp "${SCRIPT_SRC}" "${RESOURCES}/python/transcribe.py"
for pybin in "${PY_DEST}/bin/python" "${PY_DEST}/bin/python3" "${PY_DEST}"/bin/python3.*; do
  [ -f "${pybin}" ] && chmod +x "${pybin}" || true
done
rsync -a --delete "${MODEL_SRC}/" "${MODEL_DEST}/"

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
  OLD_FRAMEWORK_PREFIX="/Library/Frameworks/Python.framework/Versions/${PY_VERSION}"

  if [ -f "${FRAMEWORK_SRC}/Versions/${PY_VERSION}/Python" ]; then
    mkdir -p "${FRAMEWORK_DEST}"
    rsync -a --delete "${FRAMEWORK_SRC}/" "${FRAMEWORK_DEST}/"
    find "${FRAMEWORK_DEST}" -type f -name "python3*-intel64" -delete || true

    while IFS= read -r -d '' macho; do
      deps="$(otool -L "${macho}" 2>/dev/null | tail -n +2 | awk '{print $1}' | rg "^${OLD_FRAMEWORK_PREFIX}/" | sort -u || true)"
      ids="$(otool -D "${macho}" 2>/dev/null | tail -n +2 | rg "^${OLD_FRAMEWORK_PREFIX}/" | sort -u || true)"
      [ -z "${deps}" ] && [ -z "${ids}" ] && continue

      while IFS= read -r old_id; do
        [ -z "${old_id}" ] && continue
        suffix="${old_id#${OLD_FRAMEWORK_PREFIX}/}"
        target="${FRAMEWORK_VERSION_DEST}/${suffix}"
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
        suffix="${dep#${OLD_FRAMEWORK_PREFIX}/}"
        target="${FRAMEWORK_VERSION_DEST}/${suffix}"
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
    done < <(find "${PY_DEST}" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'Python' -o -path '*/bin/python' -o -path '*/bin/python3' -o -path '*/bin/python3.*' \) -print0)

    unresolved="$(
      find "${PY_DEST}" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'Python' -o -path '*/bin/python' -o -path '*/bin/python3' -o -path '*/bin/python3.*' \) -print0 |
      while IFS= read -r -d '' macho; do
        if otool -L "${macho}" 2>/dev/null | rg -q "${OLD_FRAMEWORK_PREFIX}"; then
          echo "${macho}"
        fi
      done
    )"
    if [ -n "${unresolved}" ]; then
      echo "Unresolved absolute Python.framework dependencies after bundling:"
      echo "${unresolved}"
      exit 1
    fi
  fi
fi
