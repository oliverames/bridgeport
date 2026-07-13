#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT="${1:-$ROOT_DIR/dist/Bridgeport.app}"
REQUIRE_NOTARIZED=0

if [ "${2:-}" = "--require-notarized" ]; then
  REQUIRE_NOTARIZED=1
elif [ -n "${2:-}" ]; then
  echo "usage: $0 [Bridgeport.app|Bridgeport.dmg] [--require-notarized]" >&2
  exit 2
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Clean-install verification requires macOS." >&2
  exit 1
fi

if [ ! -e "$ARTIFACT" ]; then
  echo "Artifact not found: $ARTIFACT" >&2
  exit 1
fi

TEMP_ROOT="$(mktemp -d /tmp/bridgeport-clean-install.XXXXXX)"
MOUNT_POINT="$TEMP_ROOT/mount"
INSTALL_DIR="$TEMP_ROOT/Applications"
INSTALL_APP="$INSTALL_DIR/Bridgeport.app"
CONFIG_HOME="$TEMP_ROOT/config"
CONNECTORS_DIR="$TEMP_ROOT/connectors"
SERVER_LOG="$TEMP_ROOT/server.log"
STATUS_JSON="$TEMP_ROOT/status.json"
TOKEN="bridgeport_clean_install_probe"
SERVER_PID=""
MOUNTED=0
ARTIFACT_KIND=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [ "$MOUNTED" -eq 1 ]; then
    diskutil eject "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$INSTALL_DIR" "$CONFIG_HOME" "$CONNECTORS_DIR"

case "$ARTIFACT" in
  *.dmg)
    ARTIFACT_KIND="dmg"
    mkdir -p "$MOUNT_POINT"
    diskutil image attach --readOnly --nobrowse --mountPoint "$MOUNT_POINT" "$ARTIFACT" >/dev/null
    MOUNTED=1
    SOURCE_APP="$MOUNT_POINT/Bridgeport.app"
    if [ ! -L "$MOUNT_POINT/Applications" ] || [ "$(readlink "$MOUNT_POINT/Applications")" != "/Applications" ]; then
      echo "DMG does not contain the expected Applications shortcut." >&2
      exit 1
    fi
    ;;
  *.app)
    ARTIFACT_KIND="app"
    SOURCE_APP="$ARTIFACT"
    ;;
  *)
    echo "Expected a Bridgeport .app bundle or .dmg: $ARTIFACT" >&2
    exit 2
    ;;
esac

if [ ! -d "$SOURCE_APP" ]; then
  echo "Bridgeport.app was not found in the artifact." >&2
  exit 1
fi

ditto "$SOURCE_APP" "$INSTALL_APP"

INFO_PLIST="$INSTALL_APP/Contents/Info.plist"
APP_BINARY="$INSTALL_APP/Contents/MacOS/bridgeport"
plutil -lint "$INFO_PLIST" >/dev/null

if [ "$(plutil -extract CFBundlePackageType raw "$INFO_PLIST")" != "APPL" ]; then
  echo "Installed bundle does not declare CFBundlePackageType=APPL." >&2
  exit 1
fi
if [ "$(plutil -extract CFBundleExecutable raw "$INFO_PLIST")" != "bridgeport" ]; then
  echo "Installed bundle does not declare the expected executable." >&2
  exit 1
fi
if [ ! -x "$APP_BINARY" ]; then
  echo "Installed Bridgeport executable is missing or is not executable." >&2
  exit 1
fi

if [ "$REQUIRE_NOTARIZED" -eq 1 ]; then
  if [ "$ARTIFACT_KIND" = "dmg" ]; then
    codesign --verify --verbose=2 "$ARTIFACT"
    xcrun stapler validate "$ARTIFACT"
    spctl -a -vv -t open --context context:primary-signature "$ARTIFACT"
  fi
  codesign --verify --deep --strict --verbose=2 "$INSTALL_APP"
  spctl -a -vv -t exec "$INSTALL_APP"
fi

PORT=""
for candidate in 48180 48181 48182 48183 48184 48185 48186 48187 48188 48189; do
  if ! nc -z 127.0.0.1 "$candidate" >/dev/null 2>&1; then
    PORT="$candidate"
    break
  fi
done

if [ -z "$PORT" ]; then
  echo "Could not find an unused local verification port." >&2
  exit 1
fi

BRIDGEPORT_CONFIG_HOME="$CONFIG_HOME" "$APP_BINARY" \
  --server \
  --port "$PORT" \
  --token "$TOKEN" \
  --connectors-path "$CONNECTORS_DIR" \
  --bind-host 127.0.0.1 \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

READY=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if curl --fail --silent --show-error --max-time 1 \
    -H "Authorization: Bearer $TOKEN" \
    "http://127.0.0.1:$PORT/status" \
    >"$STATUS_JSON" 2>/dev/null; then
    READY=1
    break
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if [ "$READY" -ne 1 ]; then
  echo "Installed Bridgeport bundle did not pass the isolated status probe." >&2
  sed "s/$TOKEN/[REDACTED]/g" "$SERVER_LOG" >&2
  exit 1
fi

if ! LC_ALL=C grep -Eq '"connectors"[[:space:]]*:' "$STATUS_JSON"; then
  echo "Installed Bridgeport status response is not the expected JSON shape." >&2
  exit 1
fi

if [ "$(stat -f '%Lp' "$CONFIG_HOME")" != "700" ]; then
  echo "Bridgeport config directory permissions are not 0700." >&2
  exit 1
fi

for generated_file in config.json mcp_config.json cloud_connectors.json; do
  path="$CONFIG_HOME/$generated_file"
  if [ ! -f "$path" ]; then
    echo "Expected generated file is missing: $generated_file" >&2
    exit 1
  fi
  if [ "$(stat -f '%Lp' "$path")" != "600" ]; then
    echo "Generated file permissions are not 0600: $generated_file" >&2
    exit 1
  fi
done

if LC_ALL=C grep -Eqi '/Users/oliverames|amesvt\.com|Oliver Ames private' "$CONFIG_HOME/config.json"; then
  echo "New-install config contains maintainer-specific defaults." >&2
  exit 1
fi

echo "Clean-install verification passed for $ARTIFACT"
