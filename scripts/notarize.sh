#!/usr/bin/env bash
# Submits a signed .dmg (or .zip) to Apple's notary service, waits for the result, and staples the ticket.
#
# Uses an App Store Connect API key:
#   NOTARY_KEY_PATH   path to the AuthKey_XXXX.p8 file
#   NOTARY_KEY_ID     the key ID
#   NOTARY_ISSUER_ID  the issuer ID
#
# Usage: ./scripts/notarize.sh dist/VoiceBarDictate-v1.0.0.dmg
set -euo pipefail

ARTIFACT="${1:-}"
if [[ -z "${ARTIFACT}" || ! -f "${ARTIFACT}" ]]; then
  echo "Usage: $0 <path-to-signed-dmg-or-zip>" >&2
  exit 1
fi

for var in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
  if [[ -z "${!var:-}" ]]; then
    echo "${var} is required for notarization." >&2
    exit 1
  fi
done

echo "Submitting ${ARTIFACT} for notarization..."
xcrun notarytool submit "${ARTIFACT}" \
  --key "${NOTARY_KEY_PATH}" \
  --key-id "${NOTARY_KEY_ID}" \
  --issuer "${NOTARY_ISSUER_ID}" \
  --wait

if [[ "${ARTIFACT}" == *.dmg ]]; then
  echo "Stapling notarization ticket..."
  xcrun stapler staple "${ARTIFACT}"
  xcrun stapler validate "${ARTIFACT}"
fi

echo "Notarized: ${ARTIFACT}"
