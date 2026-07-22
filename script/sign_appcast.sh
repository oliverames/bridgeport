#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST_PATH="${1:-$ROOT_DIR/appcast.xml}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-bridgeport}"
SIGN_UPDATE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"

if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "sign_update not found at $SIGN_UPDATE; run swift package resolve first." >&2
  exit 1
fi
if [[ ! -f "$APPCAST_PATH" ]]; then
  echo "Appcast not found: $APPCAST_PATH" >&2
  exit 1
fi

"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$APPCAST_PATH"
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$APPCAST_PATH"
echo "Signed and verified $APPCAST_PATH"
