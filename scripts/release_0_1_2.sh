#!/usr/bin/env bash
set -euo pipefail

# Automated release script for Speak macOS app:
# - archive
# - export signed .app (Developer ID)
# - build signed DMG
# - notarize DMG
# - staple + validate
#
# Required env vars:
#   TEAM_ID                 e.g. JJBQ63FWWY
#   DEVELOPER_ID_APP_CERT   e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE          keychain profile name created via notarytool store-credentials
#
# Optional env vars:
#   VERSION                 default: 0.1.2
#   BUILD_NUMBER            default: 2

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/STTMenuBar/STTMenuBar.xcodeproj"
PLIST_PATH="${ROOT_DIR}/STTMenuBar/STTMenuBar/Info.plist"
SCHEME="Speak"
CONFIG="Release"
APP_NAME="Speak"
BUNDLE_ID="com.postsoftware.speak"

VERSION="${VERSION:-0.1.2}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"

: "${TEAM_ID:?Set TEAM_ID}"
: "${DEVELOPER_ID_APP_CERT:?Set DEVELOPER_ID_APP_CERT}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE}"

OUT_DIR="${ROOT_DIR}/dist/${VERSION}"
ARCHIVE_PATH="${OUT_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${OUT_DIR}/export"
DMG_STAGING_DIR="${OUT_DIR}/dmg-staging"
DMG_PATH="${OUT_DIR}/${APP_NAME}-${VERSION}.dmg"
EXPORT_OPTIONS_PATH="${OUT_DIR}/ExportOptions.plist"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}" "${EXPORT_DIR}" "${DMG_STAGING_DIR}"

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

cp -R "${APP_PATH}" "${DMG_STAGING_DIR}/"

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
