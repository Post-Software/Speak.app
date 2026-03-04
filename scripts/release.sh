#!/usr/bin/env bash
set -euo pipefail

# Canonical release script for Speak macOS app:
# - archive
# - export signed .app (Developer ID)
# - create styled DMG using node-appdmg
# - create Sparkle ZIP + signature + appcast
# - notarize DMG
# - staple + validate
#
# Required env vars:
#   TEAM_ID
#   DEVELOPER_ID_APP_CERT
#   NOTARY_PROFILE
#   SPARKLE_PRIVATE_KEY_PATH (unless SPARKLE_SKIP=1)
#
# Optional env vars:
#   VERSION (default: 0.2)
#   BUILD_NUMBER (default: 4)
#   SCHEME (default: STTMenuBar)
#   SPARKLE_SIGN_UPDATE_BIN (default: auto-detect sign_update)
#   SPARKLE_RELEASE_BASE_URL (default: GitHub releases URL for this repo)
#   SPARKLE_APPCAST_URL (default: https://post-software.github.io/Speak.app/appcast.xml)
#   SPARKLE_SKIP (default: 0; set to 1 to skip Sparkle artifact generation)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/STTMenuBar/STTMenuBar.xcodeproj"
PLIST_PATH="${ROOT_DIR}/STTMenuBar/STTMenuBar/Info.plist"
SCHEME="${SCHEME:-STTMenuBar}"
CONFIG="Release"
APP_NAME="Speak"

RELEASE_ENV_PATH="${ROOT_DIR}/.release.env"
if [[ -f "${RELEASE_ENV_PATH}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${RELEASE_ENV_PATH}"
  set +a
fi

VERSION="${VERSION:-0.2}"
BUILD_NUMBER="${BUILD_NUMBER:-4}"
SPARKLE_SKIP="${SPARKLE_SKIP:-0}"
SPARKLE_SIGN_UPDATE_BIN="${SPARKLE_SIGN_UPDATE_BIN:-$(command -v sign_update || true)}"
SPARKLE_RELEASE_BASE_URL="${SPARKLE_RELEASE_BASE_URL:-https://github.com/Post-Software/Speak.app/releases/download/v${VERSION}}"
SPARKLE_APPCAST_URL="${SPARKLE_APPCAST_URL:-https://post-software.github.io/Speak.app/appcast.xml}"
SPARKLE_PRIVATE_KEY_PATH="${SPARKLE_PRIVATE_KEY_PATH:-}"

# DMG layout defaults
DMG_VOLNAME="${DMG_VOLNAME:-${APP_NAME}}"
DMG_WIN_X="${DMG_WIN_X:-200}"
DMG_WIN_Y="${DMG_WIN_Y:-120}"
DMG_WIN_W="${DMG_WIN_W:-720}"
DMG_WIN_H="${DMG_WIN_H:-420}"
DMG_ICON_SIZE="${DMG_ICON_SIZE:-128}"
DMG_APP_X="${DMG_APP_X:-185}"
DMG_APP_Y="${DMG_APP_Y:-210}"
DMG_APPS_X="${DMG_APPS_X:-515}"
DMG_APPS_Y="${DMG_APPS_Y:-210}"

: "${TEAM_ID:?Set TEAM_ID}"
: "${DEVELOPER_ID_APP_CERT:?Set DEVELOPER_ID_APP_CERT}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE}"
if [[ "${SPARKLE_SKIP}" != "1" ]]; then
  : "${SPARKLE_PRIVATE_KEY_PATH:?Set SPARKLE_PRIVATE_KEY_PATH (or set SPARKLE_SKIP=1)}"
fi

OUT_DIR="${ROOT_DIR}/dist/${VERSION}"
ARCHIVE_PATH="${OUT_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${OUT_DIR}/export"
DMG_STAGING_DIR="${OUT_DIR}/dmg-staging"
DMG_ASSETS_DIR="${OUT_DIR}/dmg-assets"
DMG_PATH="${OUT_DIR}/${APP_NAME}-${VERSION}.dmg"
EXPORT_OPTIONS_PATH="${OUT_DIR}/ExportOptions.plist"
APPDMG_SPEC_PATH="${OUT_DIR}/appdmg.json"
APPDMG_LOG="${OUT_DIR}/appdmg.log"
BG_IMG="${DMG_ASSETS_DIR}/background.png"
ZIP_PATH="${OUT_DIR}/${APP_NAME}-${VERSION}.zip"
SPARKLE_SIGNATURE_PATH="${OUT_DIR}/sparkle-signature.txt"
APPCAST_PATH="${OUT_DIR}/appcast.xml"
DOCS_APPCAST_PATH="${ROOT_DIR}/docs/appcast.xml"

TMP_DMG_DIR="$(mktemp -d /tmp/speak-dmg.XXXXXX)"
DMG_TMP_PATH="${TMP_DMG_DIR}/${APP_NAME}-${VERSION}.dmg"

cleanup() {
  rm -rf "${TMP_DMG_DIR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}" "${EXPORT_DIR}" "${DMG_STAGING_DIR}" "${DMG_ASSETS_DIR}"

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to build DMGs via appdmg."
  echo "Install Node.js and run: npm ci"
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required to run appdmg."
  echo "Install Node.js and run: npm ci"
  exit 1
fi

if [[ ! -x "${ROOT_DIR}/node_modules/.bin/appdmg" ]]; then
  echo "Missing local appdmg at ${ROOT_DIR}/node_modules/.bin/appdmg"
  echo "Run: npm ci"
  exit 1
fi

if ! npx --no-install appdmg --version >/dev/null 2>&1; then
  echo "Unable to execute local appdmg via npx."
  echo "Run: npm ci"
  exit 1
fi

if ! xcodebuild -project "${PROJECT_PATH}" -list | grep -q "${SCHEME}"; then
  echo "Scheme '${SCHEME}' not found in ${PROJECT_PATH}."
  echo "Run: xcodebuild -project \"${PROJECT_PATH}\" -list"
  exit 1
fi

if [[ ! -x "${ROOT_DIR}/python/.venv/bin/python" ]]; then
  echo "Missing Python runtime at ${ROOT_DIR}/python/.venv/bin/python"
  echo "Recreate it with:"
  echo "  python3 -m venv python/.venv"
  echo "  python/.venv/bin/pip install -r python/requirements.txt"
  exit 1
fi

if ! find "${ROOT_DIR}/python/.venv/lib" -path "*/site-packages/faster_whisper/__init__.py" -print -quit | grep -q .; then
  echo "faster-whisper is missing from python/.venv."
  echo "Install dependencies with:"
  echo "  python/.venv/bin/pip install -r python/requirements.txt"
  exit 1
fi

if ! find "${ROOT_DIR}/python/.venv/lib" -path "*/site-packages/huggingface_hub/__init__.py" -print -quit | grep -q .; then
  echo "huggingface_hub is missing from python/.venv."
  echo "Install dependencies with:"
  echo "  python/.venv/bin/pip install -r python/requirements.txt"
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST_PATH}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST_PATH}"

cat > "${EXPORT_OPTIONS_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST

xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -archivePath "${ARCHIVE_PATH}" \
  clean archive

xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS_PATH}"

APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Export failed: ${APP_PATH} not found"
  exit 1
fi
APP_BINARY_PATH="${APP_PATH}/Contents/MacOS/${APP_NAME}"
APP_INFO_PATH="${APP_PATH}/Contents/Info.plist"
APP_ENTITLEMENTS_PATH="${OUT_DIR}/app.entitlements.plist"

extract_app_entitlements() {
  local app_binary="$1"
  local ent_path="$2"
  if ! /usr/bin/codesign -d --entitlements :- "${app_binary}" 2>/dev/null > "${ent_path}"; then
    echo "Failed to extract signing entitlements from ${app_binary}"
    exit 1
  fi
}

verify_mic_usage_description() {
  local info_plist="$1"
  if ! /usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "${info_plist}" >/dev/null 2>&1; then
    echo "Missing NSMicrophoneUsageDescription in ${info_plist}"
    exit 1
  fi
}

verify_sparkle_runpath() {
  local app_binary="$1"
  if ! /usr/bin/otool -l "${app_binary}" | grep -A2 "LC_RPATH" | grep -q "@executable_path/../Frameworks"; then
    echo "Missing @executable_path/../Frameworks runpath on ${app_binary}"
    echo "The app will fail to launch if Sparkle.framework cannot be resolved at runtime."
    exit 1
  fi
}

has_mic_entitlement() {
  local app_binary="$1"
  local tmp_ent
  tmp_ent="$(mktemp /tmp/speak-entitlements.XXXXXX)"
  if ! /usr/bin/codesign -d --entitlements :- "${app_binary}" 2>/dev/null > "${tmp_ent}"; then
    rm -f "${tmp_ent}"
    return 1
  fi
  if grep -q "<key>com.apple.security.device.audio-input</key>" "${tmp_ent}"; then
    rm -f "${tmp_ent}"
    return 0
  fi
  rm -f "${tmp_ent}"
  return 1
}

extract_app_entitlements "${APP_BINARY_PATH}" "${APP_ENTITLEMENTS_PATH}"
verify_mic_usage_description "${APP_INFO_PATH}"
verify_sparkle_runpath "${APP_BINARY_PATH}"

if ! "${ROOT_DIR}/scripts/verify_bundled_python.sh" "${APP_PATH}"; then
  echo "Bundled Python verification failed after export. Applying fallback relink pass..."
  "${ROOT_DIR}/scripts/patch_bundled_python_refs.sh" "${APP_PATH}"
  "${ROOT_DIR}/scripts/verify_bundled_python.sh" "${APP_PATH}"
fi

prune_python_build_artifacts() {
  local app_path="$1"
  local py_root="${app_path}/Contents/Resources/python"
  [ -d "${py_root}" ] || return 0

  # Remove build-only Python artifacts that are not required at runtime and can fail notarization.
  find "${py_root}" -type d -name "config-*-darwin" -prune -exec rm -rf {} +
}

prune_python_build_artifacts "${APP_PATH}"
echo "Model weights are not bundled. End users download a model on first launch."

sign_python_executables_with_runtime() {
  local app_path="$1"
  local cert="$2"
  local py_root="${app_path}/Contents/Resources/python"
  [ -d "${py_root}" ] || return 0

  local file
  while IFS= read -r file; do
    [ -z "${file}" ] && continue
    if file "${file}" | grep -q "Mach-O"; then
      codesign --force --options runtime --timestamp --sign "${cert}" "${file}"
    fi
  done < <(find "${py_root}" -type f \( -path "*/bin/python" -o -path "*/bin/python3" -o -path "*/bin/python3.*" -o -path "*/Python.framework/Versions/*/Python" -o -path "*/Python.app/Contents/MacOS/Python" \))
}

sign_python_framework_bundles_with_runtime() {
  local app_path="$1"
  local cert="$2"
  local py_root="${app_path}/Contents/Resources/python"
  [ -d "${py_root}" ] || return 0

  local fw
  while IFS= read -r fw; do
    [ -z "${fw}" ] && continue
    codesign --force --deep --options runtime --timestamp --sign "${cert}" "${fw}"
  done < <(find "${py_root}" -type d -path "*/Python.framework")
}

sign_parakeet_worker_with_runtime() {
  local app_path="$1"
  local cert="$2"
  local worker="${app_path}/Contents/Resources/parakeet-worker"
  [ -f "${worker}" ] || return 0
  if file "${worker}" | grep -q "Mach-O"; then
    codesign --force --options runtime --timestamp --sign "${cert}" "${worker}"
  fi
}

sign_python_executables_with_runtime "${APP_PATH}" "${DEVELOPER_ID_APP_CERT}"
sign_python_framework_bundles_with_runtime "${APP_PATH}" "${DEVELOPER_ID_APP_CERT}"
sign_parakeet_worker_with_runtime "${APP_PATH}" "${DEVELOPER_ID_APP_CERT}"
echo "Re-signing exported app bundle for nested Python Mach-O consistency..."
codesign --force --options runtime --timestamp --entitlements "${APP_ENTITLEMENTS_PATH}" --sign "${DEVELOPER_ID_APP_CERT}" "${APP_PATH}"
# Sparkle framework copies can carry Finder metadata that invalidates deep verification.
# Strip xattrs from the exported app prior to verify/notarization.
xattr -cr "${APP_PATH}"

if ! codesign --verify --deep --strict --verbose=2 "${APP_PATH}"; then
  echo "Code signature verification failed for ${APP_PATH}"
  exit 1
fi

if [[ "${SPARKLE_SKIP}" != "1" ]]; then
  if [[ -z "${SPARKLE_SIGN_UPDATE_BIN}" ]]; then
    echo "sign_update was not found. Install Sparkle tools or set SPARKLE_SIGN_UPDATE_BIN."
    exit 1
  fi
  if [[ ! -x "${SPARKLE_SIGN_UPDATE_BIN}" ]]; then
    echo "SPARKLE_SIGN_UPDATE_BIN is not executable: ${SPARKLE_SIGN_UPDATE_BIN}"
    exit 1
  fi
  if [[ ! -f "${SPARKLE_PRIVATE_KEY_PATH}" ]]; then
    echo "Sparkle private key file was not found: ${SPARKLE_PRIVATE_KEY_PATH}"
    exit 1
  fi

  echo "Building Sparkle archive..."
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"
  ZIP_SIZE="$(stat -f%z "${ZIP_PATH}")"
  ARCHIVE_URL="${SPARKLE_RELEASE_BASE_URL}/${APP_NAME}-${VERSION}.zip"
  PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"

  sign_update_output=""
  if sign_update_output="$("${SPARKLE_SIGN_UPDATE_BIN}" "${ZIP_PATH}" "${SPARKLE_PRIVATE_KEY_PATH}" 2>&1)"; then
    :
  elif sign_update_output="$("${SPARKLE_SIGN_UPDATE_BIN}" -p "${SPARKLE_PRIVATE_KEY_PATH}" "${ZIP_PATH}" 2>&1)"; then
    :
  elif sign_update_output="$("${SPARKLE_SIGN_UPDATE_BIN}" --ed-key-file "${SPARKLE_PRIVATE_KEY_PATH}" "${ZIP_PATH}" 2>&1)"; then
    :
  else
    echo "Failed to sign Sparkle archive with sign_update."
    echo "${sign_update_output}"
    exit 1
  fi

  printf "%s\n" "${sign_update_output}" > "${SPARKLE_SIGNATURE_PATH}"

  SPARKLE_ED_SIGNATURE="$(
    printf "%s\n" "${sign_update_output}" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -n1
  )"

  if [[ -z "${SPARKLE_ED_SIGNATURE}" ]]; then
    echo "Unable to parse sparkle:edSignature from sign_update output."
    echo "Output was:"
    cat "${SPARKLE_SIGNATURE_PATH}"
    exit 1
  fi

  cat > "${APPCAST_PATH}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Speak Updates</title>
    <link>${SPARKLE_APPCAST_URL}</link>
    <description>Speak macOS release feed</description>
    <language>en</language>
    <item>
      <title>Speak ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure url="${ARCHIVE_URL}"
                 sparkle:version="${BUILD_NUMBER}"
                 sparkle:shortVersionString="${VERSION}"
                 length="${ZIP_SIZE}"
                 type="application/octet-stream"
                 sparkle:edSignature="${SPARKLE_ED_SIGNATURE}" />
    </item>
  </channel>
</rss>
XML

  mkdir -p "$(dirname "${DOCS_APPCAST_PATH}")"
  cp "${APPCAST_PATH}" "${DOCS_APPCAST_PATH}"
else
  echo "SPARKLE_SKIP=1 set. Skipping Sparkle ZIP/signature/appcast generation."
fi

MIC_ENTITLEMENT_PRESENT="no"
if has_mic_entitlement "${APP_BINARY_PATH}"; then
  MIC_ENTITLEMENT_PRESENT="yes"
else
  echo "Missing com.apple.security.device.audio-input entitlement on ${APP_BINARY_PATH}"
  exit 1
fi

cp -R "${APP_PATH}" "${DMG_STAGING_DIR}/"

# Create gray background with in-window install instruction text.
xcrun swift - "${BG_IMG}" <<'SWIFT'
import AppKit

let outputPath = CommandLine.arguments[1]
let width: CGFloat = 720
let height: CGFloat = 420

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()
NSColor(calibratedWhite: 0.90, alpha: 1.0).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

let title = "Drag Speak into Applications"
let subtitle = "Install locally in one step"
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.20, alpha: 1.0),
    .paragraphStyle: paragraph
]

let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 16, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.28, alpha: 1.0),
    .paragraphStyle: paragraph
]

(title as NSString).draw(
    in: NSRect(x: 24, y: 36, width: width - 48, height: 46),
    withAttributes: titleAttrs
)

(subtitle as NSString).draw(
    in: NSRect(x: 24, y: 14, width: width - 48, height: 26),
    withAttributes: subtitleAttrs
)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fputs("Failed to render background image\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
SWIFT

cat > "${APPDMG_SPEC_PATH}" <<JSON
{
  "title": "${DMG_VOLNAME}",
  "background": "dmg-assets/background.png",
  "icon-size": ${DMG_ICON_SIZE},
  "window": {
    "position": { "x": ${DMG_WIN_X}, "y": ${DMG_WIN_Y} },
    "size": { "width": ${DMG_WIN_W}, "height": ${DMG_WIN_H} }
  },
  "format": "UDZO",
  "filesystem": "HFS+",
  "contents": [
    { "x": ${DMG_APP_X}, "y": ${DMG_APP_Y}, "type": "file", "path": "dmg-staging/${APP_NAME}.app" },
    { "x": ${DMG_APPS_X}, "y": ${DMG_APPS_Y}, "type": "link", "path": "/Applications" }
  ]
}
JSON

rm -f "${APPDMG_LOG}"
echo "Building DMG with node-appdmg..."
if ! npx --no-install appdmg "${APPDMG_SPEC_PATH}" "${DMG_TMP_PATH}" > "${APPDMG_LOG}" 2>&1; then
  echo "appdmg failed. See log: ${APPDMG_LOG}"
  cat "${APPDMG_LOG}" || true
  exit 1
fi

if [[ ! -f "${DMG_TMP_PATH}" ]]; then
  echo "appdmg did not produce DMG at ${DMG_TMP_PATH}"
  echo "See log: ${APPDMG_LOG}"
  exit 1
fi

mv -f "${DMG_TMP_PATH}" "${DMG_PATH}"

codesign --force --sign "${DEVELOPER_ID_APP_CERT}" --timestamp "${DMG_PATH}"

NOTARY_RESULT_JSON="${OUT_DIR}/notary_submit_result.json"
if ! xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait --output-format json > "${NOTARY_RESULT_JSON}"; then
  echo "Notary submission failed:"
  cat "${NOTARY_RESULT_JSON}" || true
  exit 1
fi

NOTARY_ID="$(
/usr/bin/python3 - "${NOTARY_RESULT_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data.get("id", ""))
PY
)"
NOTARY_STATUS="$(
/usr/bin/python3 - "${NOTARY_RESULT_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data.get("status", ""))
PY
)"

if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
  echo "Notary status is '${NOTARY_STATUS}' (expected 'Accepted')."
  if [[ -n "${NOTARY_ID}" ]]; then
    NOTARY_LOG_JSON="${OUT_DIR}/notary_log_${NOTARY_ID}.json"
    xcrun notarytool log "${NOTARY_ID}" --keychain-profile "${NOTARY_PROFILE}" "${NOTARY_LOG_JSON}" || true
    if [[ -f "${NOTARY_LOG_JSON}" ]]; then
      echo "Notary log:"
      cat "${NOTARY_LOG_JSON}"
    fi
  fi
  exit 1
fi

echo "Notary accepted (id: ${NOTARY_ID})."
stapled=0
STAPLED_STATUS="no"
for attempt in 1 2 3 4 5 6 7 8; do
  if xcrun stapler staple "${DMG_PATH}"; then
    stapled=1
    STAPLED_STATUS="yes"
    break
  fi
  echo "Stapler attempt ${attempt}/8 failed. Retrying in 20s..."
  sleep 20
done

if [[ "${stapled}" -ne 1 ]]; then
  echo "Stapling failed after retries."
  exit 1
fi

spctl -a -vvv -t open "${DMG_PATH}" || true
xcrun stapler validate "${DMG_PATH}" || true

echo "Mic entitlement present: ${MIC_ENTITLEMENT_PRESENT}"
echo "Notary status: ${NOTARY_STATUS}"
echo "Stapled: ${STAPLED_STATUS}"
if [[ "${SPARKLE_SKIP}" != "1" ]]; then
  echo "Sparkle archive: ${ZIP_PATH}"
  echo "Sparkle signature output: ${SPARKLE_SIGNATURE_PATH}"
  echo "Sparkle appcast (dist): ${APPCAST_PATH}"
  echo "Sparkle appcast (docs): ${DOCS_APPCAST_PATH}"
fi
echo "DMG builder: appdmg"
echo "appdmg spec: ${APPDMG_SPEC_PATH}"
echo "appdmg log: ${APPDMG_LOG}"
echo "Release ready: ${DMG_PATH}"
