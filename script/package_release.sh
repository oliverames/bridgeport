#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-1.0}"
APP_NAME="Bridgeport"
BINARY_NAME="bridgeport"
BUNDLE_ID="com.oliverames.bridgeport"
MIN_SYSTEM_VERSION="26.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/dist/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$BINARY_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
DMG_STAGING_DIR="$RELEASE_DIR/.dmg-staging"
APP_ICON="$ROOT_DIR/Resources/AppIcon.icns"

cleanup() {
  rm -rf "$DMG_STAGING_DIR"
}
trap cleanup EXIT

find_signing_identity() {
  if [ -n "${BRIDGEPORT_SIGN_IDENTITY:-}" ]; then
    printf '%s\n' "$BRIDGEPORT_SIGN_IDENTITY"
    return 0
  fi

  security find-identity -p codesigning -v 2>/dev/null \
    | awk -F '"' '/Developer ID Application/ { print $2; exit }'
}

SIGN_IDENTITY="$(find_signing_identity)"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "No Developer ID Application signing identity found." >&2
  echo "Set BRIDGEPORT_SIGN_IDENTITY to a valid codesigning identity and rerun." >&2
  exit 1
fi

rm -rf "$APP_BUNDLE" "$DMG_PATH" "$DMG_STAGING_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

swift build -c release
BUILD_BINARY="$(swift build -c release --show-bin-path)/$BINARY_NAME"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [ -f "$APP_ICON" ]; then
  cp "$APP_ICON" "$APP_RESOURCES/AppIcon.icns"
fi

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
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
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
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST"

codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$DMG_STAGING_DIR"
ditto "$APP_BUNDLE" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

diskutil image create from \
  --format UDZO \
  --volumeName "$APP_NAME $VERSION" \
  "$DMG_STAGING_DIR" \
  "$DMG_PATH"

codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "$DMG_PATH"
