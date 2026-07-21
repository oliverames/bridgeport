#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Bridgeport"
BINARY_NAME="bridgeport"
BUNDLE_ID="com.oliverames.bridgeport"
MIN_SYSTEM_VERSION="26.0"
VERSION="${BRIDGEPORT_VERSION:-1.0.9}"
BUILD="${BRIDGEPORT_BUILD:-dev}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$BINARY_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$ROOT_DIR/Resources/AppIcon.icns"

case "$MODE" in
  run|--build-only|build-only|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

# Stop only the app bundle assembled by this script. Do not stop an installed
# LaunchAgent daemon that may be serving real connector sessions.
if [ -d "$APP_BUNDLE" ]; then
  while IFS= read -r pid; do
    kill "$pid" >/dev/null 2>&1 || true
  done < <(pgrep -f "$APP_BINARY" || true)
fi

# Build using SwiftPM
swift build

# Get the path of the built binary
BUILD_BINARY="$(swift build --show-bin-path)/$BINARY_NAME"

# Assemble the App Bundle
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [ -f "$APP_ICON" ]; then
  cp "$APP_ICON" "$APP_RESOURCES/AppIcon.icns"
fi

# Embed Sparkle.framework; the binary links it with an
# @executable_path/../Frameworks rpath (see Package.swift).
SPARKLE_FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
  echo "Sparkle.framework not found at $SPARKLE_FRAMEWORK; run swift package resolve" >&2
  exit 1
fi
mkdir -p "$APP_CONTENTS/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP_CONTENTS/Frameworks/Sparkle.framework"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$BINARY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright 2026 Oliver Ames. All rights reserved.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Bridgeport runs local MCP connectors that automate Mac apps such as Notes on your behalf.</string>
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/oliverames/bridgeport/main/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>5ijlL6wlqyqe1jvOlMQhlf2ntqVKfhnxR5lp58iKpT0=</string>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
</dict>
</plist>
PLIST

open_app() {
  echo "Launching $APP_NAME..."
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --build-only|build-only)
    echo "$APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$BINARY_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
esac
