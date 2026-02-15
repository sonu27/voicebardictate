#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VoiceBarDictate"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}" # debug|release
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
APP_DIR="${APP_DIR:-${DIST_DIR}/${APP_NAME}.app}"
PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-com.example.VoiceBarDictate}"
MIC_USAGE_DESCRIPTION="${MIC_USAGE_DESCRIPTION:-VoiceBarDictate uses your microphone only while dictation is active.}"
SIGNING_MODE="${SIGNING_MODE:-adhoc}" # adhoc|selfcert
OPEN_APP="${OPEN_APP:-0}" # 1 to open after build

cd "${ROOT_DIR}"

echo "Building ${APP_NAME} (${BUILD_CONFIGURATION})..."
swift build -c "${BUILD_CONFIGURATION}"

binary_path="${ROOT_DIR}/.build/${BUILD_CONFIGURATION}/${APP_NAME}"
if [[ ! -x "${binary_path}" ]]; then
  binary_path="$(find "${ROOT_DIR}/.build" -type f -path "*/${BUILD_CONFIGURATION}/${APP_NAME}" | head -n 1 || true)"
fi

if [[ -z "${binary_path}" || ! -x "${binary_path}" ]]; then
  echo "Could not find built binary for ${APP_NAME}." >&2
  exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"

cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${PRODUCT_BUNDLE_IDENTIFIER}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>${MIC_USAGE_DESCRIPTION}</string>
</dict>
</plist>
EOF

cp "${binary_path}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

case "${SIGNING_MODE}" in
  adhoc)
    echo "Signing app bundle with ad-hoc signature..."
    codesign --force --deep --timestamp=none --sign - "${APP_DIR}"
    ;;
  selfcert)
    if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
      cat >&2 <<'EOF'
SIGNING_MODE=selfcert requires CODE_SIGN_IDENTITY.
Example:
  SIGNING_MODE=selfcert CODE_SIGN_IDENTITY="VoiceBarDictate Local Self Sign" ./scripts/build-app-bundle.sh
EOF
      exit 1
    fi
    echo "Signing app bundle with local certificate: ${CODE_SIGN_IDENTITY}"
    codesign --force --deep --timestamp=none --sign "${CODE_SIGN_IDENTITY}" "${APP_DIR}"
    ;;
  *)
    echo "Invalid SIGNING_MODE='${SIGNING_MODE}'. Use adhoc or selfcert." >&2
    exit 1
    ;;
esac

codesign --verify --deep --strict "${APP_DIR}"

echo "App bundle created: ${APP_DIR}"
echo "Launch with: open \"${APP_DIR}\""

if [[ "${OPEN_APP}" == "1" ]]; then
  open "${APP_DIR}"
fi
