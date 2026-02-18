#!/usr/bin/env bash
set -euo pipefail

# Reliable release script for Speak macOS app:
# - archive
# - export signed .app (Developer ID)
# - create DMG using 0.1.2 Finder layout template
# - notarize DMG
# - staple + validate
#
# Required env vars:
#   TEAM_ID
#   DEVELOPER_ID_APP_CERT
#   NOTARY_PROFILE
#
# Optional env vars:
#   VERSION (default: 0.1.3)
#   BUILD_NUMBER (default: 3)
#   SCHEME (default: STTMenuBar)
#   DMG_TEMPLATE_PATH (default: dist/0.1.2/Speak-0.1.2.dmg)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/STTMenuBar/STTMenuBar.xcodeproj"
PLIST_PATH="${ROOT_DIR}/STTMenuBar/STTMenuBar/Info.plist"
SCHEME="${SCHEME:-STTMenuBar}"
CONFIG="Release"
APP_NAME="Speak"

RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-${ROOT_DIR}/.release.env}"
if [ -f "${RELEASE_ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${RELEASE_ENV_FILE}"
  set +a
fi

VERSION="${VERSION:-0.1.3}"
BUILD_NUMBER="${BUILD_NUMBER:-3}"

: "${TEAM_ID:?Set TEAM_ID}"
: "${DEVELOPER_ID_APP_CERT:?Set DEVELOPER_ID_APP_CERT}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE}"

OUT_DIR="${ROOT_DIR}/dist/${VERSION}"
ARCHIVE_PATH="${OUT_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${OUT_DIR}/export"
DMG_STAGING_DIR="${OUT_DIR}/dmg-staging"
DMG_PATH="${OUT_DIR}/${APP_NAME}-${VERSION}.dmg"
EXPORT_OPTIONS_PATH="${OUT_DIR}/ExportOptions.plist"
DMG_TEMPLATE_PATH="${DMG_TEMPLATE_PATH:-${ROOT_DIR}/dist/0.1.2/Speak-0.1.2.dmg}"

TMP_DMG_DIR="$(mktemp -d /tmp/speak-dmg.XXXXXX)"
TEMPLATE_MOUNT="${TMP_DMG_DIR}/template-mount"
BG_IMG="${DMG_STAGING_DIR}/.background/background.png"

cleanup() {
  if mount | grep -Fq "on ${TEMPLATE_MOUNT} "; then
    hdiutil detach "${TEMPLATE_MOUNT}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP_DMG_DIR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}" "${EXPORT_DIR}" "${DMG_STAGING_DIR}"

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

"${ROOT_DIR}/scripts/patch_bundled_python_refs.sh" "${APP_PATH}"
"${ROOT_DIR}/scripts/verify_bundled_python.sh" "${APP_PATH}"

codesign --force --deep --options runtime --timestamp --sign "${DEVELOPER_ID_APP_CERT}" "${APP_PATH}"

if ! codesign --verify --deep --strict --verbose=2 "${APP_PATH}"; then
  echo "Code signature verification failed for ${APP_PATH}"
  exit 1
fi

cp -R "${APP_PATH}" "${DMG_STAGING_DIR}/"
rm -f "${DMG_STAGING_DIR}/Applications"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"
mkdir -p "${DMG_STAGING_DIR}/.background"

if [[ ! -f "${DMG_TEMPLATE_PATH}" ]]; then
  echo "DMG template not found: ${DMG_TEMPLATE_PATH}"
  echo "Set DMG_TEMPLATE_PATH to your working styled DMG (for example dist/0.1.2/Speak-0.1.2.dmg)."
  exit 1
fi

mkdir -p "${TEMPLATE_MOUNT}"
hdiutil attach -nobrowse -readonly -mountpoint "${TEMPLATE_MOUNT}" "${DMG_TEMPLATE_PATH}" >/dev/null
if [[ ! -f "${TEMPLATE_MOUNT}/.DS_Store" ]]; then
  echo "Template DMG is missing .DS_Store: ${DMG_TEMPLATE_PATH}"
  hdiutil detach "${TEMPLATE_MOUNT}" >/dev/null || true
  exit 1
fi
if [[ ! -d "${TEMPLATE_MOUNT}/.background" ]]; then
  echo "Template DMG is missing .background: ${DMG_TEMPLATE_PATH}"
  hdiutil detach "${TEMPLATE_MOUNT}" >/dev/null || true
  exit 1
fi
cp -f "${TEMPLATE_MOUNT}/.DS_Store" "${DMG_STAGING_DIR}/.DS_Store"
rm -rf "${DMG_STAGING_DIR}/.background"
cp -R "${TEMPLATE_MOUNT}/.background" "${DMG_STAGING_DIR}/.background"
hdiutil detach "${TEMPLATE_MOUNT}" >/dev/null

# Keep the 0.1.2 Finder layout while updating the instruction copy.
xcrun swift - "${BG_IMG}" <<'SWIFT'
import AppKit

let outputPath = CommandLine.arguments[1]
let width: CGFloat = 640
let height: CGFloat = 400

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()
NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

let text = "Drag the Speak app icon to Applications,\nthen open the Speak app from Applications"
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center

let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .regular),
    .foregroundColor: NSColor.secondaryLabelColor,
    .paragraphStyle: paragraph
]

(text as NSString).draw(
    in: NSRect(x: 24, y: 24, width: width - 48, height: 66),
    withAttributes: attrs
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

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

codesign --force --sign "${DEVELOPER_ID_APP_CERT}" --timestamp "${DMG_PATH}"

xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG_PATH}"

spctl -a -vvv -t open "${DMG_PATH}" || true
xcrun stapler validate "${DMG_PATH}" || true

echo "Release ready: ${DMG_PATH}"
