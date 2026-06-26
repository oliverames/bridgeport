#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="${1:-dist/release/Bridgeport-1.0.dmg}"
CLAUDE_ENV="${CLAUDE_ENV:-$HOME/.claude/.env}"
APP_STORE_CONNECT_KEY_ITEM="${APP_STORE_CONNECT_KEY_ITEM:-App Store Connect AuthKey (.p8)}"
APP_STORE_CONNECT_VAULT="${APP_STORE_CONNECT_VAULT:-Development}"

if [ ! -f "$DMG_PATH" ]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

TMP_KEY="$(mktemp /tmp/bridgeport-notary-key.XXXXXX.p8)"
TMP_ENV="$(mktemp /tmp/bridgeport-notary-env.XXXXXX)"

cleanup() {
  rm -f "$TMP_KEY" "$TMP_ENV"
}
trap cleanup EXIT

python3 - "$CLAUDE_ENV" "$TMP_ENV" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).expanduser()
target = pathlib.Path(sys.argv[2])
wanted = {"APP_STORE_CONNECT_API_KEY", "APP_STORE_CONNECT_ISSUER_ID"}
lines = []

for raw in source.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key = line.split("=", 1)[0].replace("export ", "").strip()
    if key in wanted:
        lines.append(line)

missing = wanted.difference(line.split("=", 1)[0].replace("export ", "").strip() for line in lines)
if missing:
    raise SystemExit(f"Missing App Store Connect env reference(s): {', '.join(sorted(missing))}")

target.write_text("\n".join(lines) + "\n")
PY

op document get "$APP_STORE_CONNECT_KEY_ITEM" \
  --vault "$APP_STORE_CONNECT_VAULT" \
  --force \
  --out-file "$TMP_KEY" >/dev/null

chmod 600 "$TMP_KEY"

op run --env-file="$TMP_ENV" -- sh -c \
  'xcrun notarytool submit "$1" --key "$2" --key-id "$APP_STORE_CONNECT_API_KEY" --issuer "$APP_STORE_CONNECT_ISSUER_ID" --wait' \
  sh "$DMG_PATH" "$TMP_KEY"

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
