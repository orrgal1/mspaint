#!/usr/bin/env bash
# Builds Paint in release configuration and packages it as Paint.app.
# Usage: bash build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="Paint"
BUNDLE_ID="com.local.PaintMac"
VERSION="1.0"
BUILD="1"

APP_DIR="$ROOT/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Building $APP_NAME (release)"
swift build --configuration release --product "$APP_NAME"

BIN_PATH="$(swift build --configuration release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built executable not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.graphics-design</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
    echo "==> Ad-hoc signing"
    codesign --force --sign - "$APP_DIR"
fi

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
fi

echo "==> Built $APP_DIR"
echo "    open '$APP_NAME.app'  # or: open -a \"\$PWD/$APP_NAME.app\""
