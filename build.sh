#!/bin/bash
# Builds video2live and packages it into a signed .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="video2live"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

echo "==> Compiling (release)…"
swift build -c release

echo "==> Assembling $APP_BUNDLE …"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Ad-hoc code signing…"
codesign --force --deep --sign - \
    --identifier com.shawn.video2live \
    "$APP_BUNDLE"

echo ""
echo "✅ 完成：$(pwd)/$APP_BUNDLE"
echo "   运行：open \"$APP_BUNDLE\"   或在访达中双击。"
