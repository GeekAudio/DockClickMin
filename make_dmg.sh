#!/bin/bash
# 打 DMG：app + Applications 软链 + 使用说明.html（说明页不含下载链接，适合随包分发）
#   ./make_dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="DockClickMin"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="$APP-$VERSION.dmg"

[ -d "$APP.app" ] || { echo "缺少 $APP.app，先跑 ./build.sh"; exit 1; }
[ -f "assets/使用说明.html" ] || { echo "缺少 assets/使用说明.html"; exit 1; }

STAGE=$(mktemp -d)/stage
mkdir -p "$STAGE"

echo "==> 组装 $APP $VERSION"
ditto --norsrc --noextattr "$APP.app" "$STAGE/$APP.app"
ln -s /Applications "$STAGE/Applications"
cp "assets/使用说明.html" "$STAGE/使用说明.html"

echo "==> 生成 DMG"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify -quiet "$DMG"

echo "==> 校验"
ls -lh "$DMG"
shasum -a 256 "$DMG"
echo "内容："
hdiutil attach -nobrowse -readonly -mountpoint /tmp/dcm-dmg "$DMG" >/dev/null
ls -1 /tmp/dcm-dmg
hdiutil detach -quiet /tmp/dcm-dmg

echo "OK: $PWD/$DMG"
