#!/bin/bash
# Builds ClaudeUsage.app (menu bar only). Usage:
#   ./build.sh            build into ./build/ClaudeUsage.app
#   ./build.sh install    build, then install to ~/Applications and launch
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="ClaudeUsage"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION="1.0.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: one swiftc pass per arch, then lipo. Still a two-second build, and
# the .app runs on Intel Macs too, which matters for anything handed to someone else.
ARCHS=(arm64 x86_64)
SLICES=()
for arch in "${ARCHS[@]}"; do
    echo "==> Compiling ($arch)"
    slice="$BUILD_DIR/$APP_NAME-$arch"
    swiftc -O -parse-as-library \
        -target "$arch-apple-macos13.0" \
        -o "$slice" \
        Sources/*.swift \
        -framework AppKit -framework SwiftUI -framework ServiceManagement
    SLICES+=("$slice")
done

lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
rm -f "${SLICES[@]}"

cp Resources/*.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Claude Usage</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.andres.claudeusage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier com.andres.claudeusage "$APP"

echo "==> Built $APP"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Applications/$APP_NAME.app"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "$DEST"
    mkdir -p "$HOME/Applications"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "==> Installed and launched $DEST"
fi
