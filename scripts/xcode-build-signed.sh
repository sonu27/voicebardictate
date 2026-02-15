#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install full Xcode first." >&2
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  active_dir="$(xcode-select -p 2>/dev/null || true)"
  echo "xcodebuild is unavailable for the active developer directory (${active_dir:-unknown})." >&2
  echo "Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

SCHEME="${SCHEME:-VoiceBarDictate}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.build/XcodeDerivedData}"
PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-com.example.VoiceBarDictate}"
SIGNING_MODE="${SIGNING_MODE:-auto}" # auto|adhoc|selfcert|apple

if [[ "${SIGNING_MODE}" == "auto" ]]; then
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    SIGNING_MODE="apple"
  else
    SIGNING_MODE="adhoc"
  fi
fi

build_signing_args=()

case "${SIGNING_MODE}" in
  adhoc)
    echo "Using ad-hoc local signing (no Apple membership needed)."
    build_signing_args=(
      CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO
      PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER}"
    )
    ;;
  selfcert)
    if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
      cat >&2 <<'EOF'
SIGNING_MODE=selfcert requires CODE_SIGN_IDENTITY.
Example:
  SIGNING_MODE=selfcert CODE_SIGN_IDENTITY="My Local Mac Dev Cert" ./scripts/xcode-build-signed.sh

To list identities:
  security find-identity -v -p codesigning
EOF
      exit 1
    fi
    echo "Using local self-signed certificate: ${CODE_SIGN_IDENTITY}"
    build_signing_args=(
      CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO
      PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER}"
    )
    ;;
  apple)
    if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
      echo "SIGNING_MODE=apple requires DEVELOPMENT_TEAM." >&2
      exit 1
    fi
    CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development}"
    echo "Using Apple signing (DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM})."
    build_signing_args=(
      CODE_SIGN_STYLE=Automatic
      DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}"
      PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER}"
      CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}"
    )
    ;;
  *)
    echo "Invalid SIGNING_MODE='${SIGNING_MODE}'. Use auto, adhoc, selfcert, or apple." >&2
    exit 1
    ;;
esac

echo "Building ${SCHEME} (${CONFIGURATION})..."

xcodebuild \
  -scheme "${SCHEME}" \
  -destination "platform=macOS" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build \
  "${build_signing_args[@]}"

products_dir="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}"
app_path="$(find "${products_dir}" -maxdepth 1 -type d -name "*.app" | head -n 1 || true)"
binary_path="${products_dir}/VoiceBarDictate"

if [[ -n "${app_path}" ]]; then
  sign_target="${app_path}"
elif [[ -x "${binary_path}" ]]; then
  sign_target="${binary_path}"
else
  echo "Build complete. Inspect products in ${products_dir}" >&2
  exit 1
fi

if [[ "${SIGNING_MODE}" == "adhoc" ]]; then
  codesign --force --deep --timestamp=none --sign - "${sign_target}"
  codesign --verify --deep --strict "${sign_target}"
  echo "Build complete (ad-hoc signed): ${sign_target}"
elif [[ "${SIGNING_MODE}" == "selfcert" ]]; then
  codesign --force --deep --timestamp=none --sign "${CODE_SIGN_IDENTITY}" "${sign_target}"
  codesign --verify --deep --strict "${sign_target}"
  echo "Build complete (self-signed): ${sign_target}"
else
  echo "Build complete (Apple signed): ${sign_target}"
fi
