#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 VERSION FIRMWARE_BIN DOWNLOAD_URL" >&2
  exit 2
fi

VERSION=$1
FIRMWARE=$2
URL=$3
KEY=${RLCD_SIGNING_KEY:-$HOME/.config/claude-rlcd/firmware-signing-key.pem}

[ -f "$FIRMWARE" ] || { echo "Firmware not found: $FIRMWARE" >&2; exit 1; }
[ -f "$KEY" ] || { echo "Signing key not found: $KEY" >&2; exit 1; }
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "Version must look like 1.2.3" >&2; exit 1;
}

SHA=$(sha256sum "$FIRMWARE" | awk '{print $1}')
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
printf '%s\n%s\n%s\n' "$VERSION" "$URL" "$SHA" > "$TMP"
SIG=$(openssl dgst -sha256 -sign "$KEY" "$TMP" | base64 -w0)

printf '{\n  "version": "%s",\n  "url": "%s",\n  "sha256": "%s",\n  "signature": "%s"\n}\n' \
  "$VERSION" "$URL" "$SHA" "$SIG"
