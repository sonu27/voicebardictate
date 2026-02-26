#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-VoiceBarDictate}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
APP_DIR="${APP_DIR:-${DIST_DIR}/${APP_NAME}.app}"
DMG_NAME="${DMG_NAME:-${APP_NAME}.dmg}"
VOL_NAME="${VOL_NAME:-VoiceBarDictate}"

mkdir -p "${DIST_DIR}"

if [[ "${STAGING_DIR:-}" == "" ]]; then
  STAGING_DIR="$(mktemp -d "${DIST_DIR}/dmg-staging.XXXXXX")"
  CLEANUP_STAGING_DIR=1
else
  CLEANUP_STAGING_DIR=0
fi

cleanup() {
  if [[ "${CLEANUP_STAGING_DIR}" == "1" && -d "${STAGING_DIR}" ]]; then
    rm -rf "${STAGING_DIR}"
  fi
}
trap cleanup EXIT

if [[ ! -d "${APP_DIR}" ]]; then
  echo "App bundle not found: ${APP_DIR}" >&2
  echo "Build it first with ./scripts/build-app-bundle.sh" >&2
  exit 1
fi

mkdir -p "${STAGING_DIR}"

STAGING_APP_DIR="${STAGING_DIR}/${APP_NAME}.app"
if [[ -e "${STAGING_APP_DIR}" ]]; then
  rm -rf "${STAGING_APP_DIR}"
fi

cp -R "${APP_DIR}" "${STAGING_APP_DIR}"
ln -sfn /Applications "${STAGING_DIR}/Applications"

DMG_PATH="${DIST_DIR}/${DMG_NAME}"
if [[ -f "${DMG_PATH}" ]]; then
  rm -f "${DMG_PATH}"
fi

echo "Creating DMG: ${DMG_PATH}"
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

if [[ "${GENERATE_SHA256:-0}" == "1" ]]; then
  SHA_PATH="${DMG_PATH}.sha256"
  shasum -a 256 "${DMG_PATH}" > "${SHA_PATH}"
  echo "SHA256: ${SHA_PATH}"
fi

echo "DMG created: ${DMG_PATH}"
