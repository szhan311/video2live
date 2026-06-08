#!/bin/bash
# Builds video2live.app (via build.sh) and packages it into a distributable .dmg.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="video2live"
APP_BUNDLE="$APP_NAME.app"
DMG="$APP_NAME.dmg"
VOL_NAME="$APP_NAME"

# 1. Make sure we have a fresh, signed .app.
./build.sh

# 2. Stage the .app plus an /Applications shortcut for drag-install.
echo "==> Building $DMG …"
STAGE="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3. Create a compressed disk image.
rm -f "$DMG"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

rm -rf "$STAGE"

echo ""
echo "✅ 完成：$(pwd)/$DMG"
echo "   分发：把 $DMG 发给别人；打开后把 $APP_BUNDLE 拖到 Applications 即可。"
