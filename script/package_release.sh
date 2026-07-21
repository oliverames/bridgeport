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

# Embed Sparkle.framework; the binary links it with an
# @executable_path/../Frameworks rpath (see Package.swift).
SPARKLE_FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
  echo "Sparkle.framework not found at $SPARKLE_FRAMEWORK; run swift package resolve" >&2
  exit 1
fi
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
mkdir -p "$APP_FRAMEWORKS"
ditto "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"

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

plutil -lint "$INFO_PLIST"

# Sparkle's nested executables must be signed individually (inside-out)
# before the framework and app; --deep does not apply the runtime option
# or preserve the XPC services' entitlements correctly.
EMBEDDED_SPARKLE="$APP_FRAMEWORKS/Sparkle.framework"
codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
  --sign "$SIGN_IDENTITY" "$EMBEDDED_SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
  --sign "$SIGN_IDENTITY" "$EMBEDDED_SPARKLE/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$EMBEDDED_SPARKLE/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$EMBEDDED_SPARKLE/Versions/B/Updater.app"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$EMBEDDED_SPARKLE"

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
