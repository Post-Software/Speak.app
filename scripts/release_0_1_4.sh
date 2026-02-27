#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=0.1.4 BUILD_NUMBER=4 "${SCRIPT_DIR}/release.sh" "$@"
