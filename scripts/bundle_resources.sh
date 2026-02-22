#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "${SRCROOT}/.." && pwd)"
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
RUST_ROOT="${ROOT}/rust-transcriber"
MANIFEST="${RUST_ROOT}/Cargo.toml"

if [[ ! -f "${MANIFEST}" ]]; then
  echo "Missing Rust transcriber manifest at ${MANIFEST}"
  exit 1
fi

resolve_cargo() {
  if command -v cargo >/dev/null 2>&1; then
    command -v cargo
    return 0
  fi

  if [[ -f "${HOME}/.cargo/env" ]]; then
    # shellcheck disable=SC1090
    source "${HOME}/.cargo/env"
    if command -v cargo >/dev/null 2>&1; then
      command -v cargo
      return 0
    fi
  fi

  for candidate in \
    "${HOME}/.cargo/bin/cargo" \
    "/opt/homebrew/bin/cargo" \
    "/usr/local/bin/cargo"
  do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  return 1
}

if ! CARGO_BIN="$(resolve_cargo)"; then
  echo "cargo is required to build speak-transcriber but was not found in Xcode shell PATH."
  echo "Install Rust once on the build machine and retry:"
  echo "  curl https://sh.rustup.rs -sSf | sh -s -- -y"
  echo "  source \"\$HOME/.cargo/env\""
  exit 1
fi

PROFILE="release"
if [[ "${CONFIGURATION:-Debug}" == "Debug" ]]; then
  PROFILE="debug"
fi

echo "Using cargo at: ${CARGO_BIN}"
echo "Building Rust sidecar (profile=${PROFILE})"
if [[ "${PROFILE}" == "release" ]]; then
  "${CARGO_BIN}" build --manifest-path "${MANIFEST}" --release
else
  "${CARGO_BIN}" build --manifest-path "${MANIFEST}"
fi

BIN_SRC="${RUST_ROOT}/target/${PROFILE}/speak-transcriber"
if [[ ! -x "${BIN_SRC}" ]]; then
  echo "Expected sidecar binary missing: ${BIN_SRC}"
  exit 1
fi

BIN_DEST_DIR="${RESOURCES}/bin"
mkdir -p "${BIN_DEST_DIR}"
cp -f "${BIN_SRC}" "${BIN_DEST_DIR}/speak-transcriber"
chmod +x "${BIN_DEST_DIR}/speak-transcriber"

echo "Bundled sidecar to ${BIN_DEST_DIR}/speak-transcriber"
