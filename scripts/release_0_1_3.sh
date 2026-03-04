#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=0.1.3 BUILD_NUMBER=3 "${SCRIPT_DIR}/release.sh" "$@"
