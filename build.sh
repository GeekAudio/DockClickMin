#!/bin/bash
# DockClickMin 构建脚本
#   ./build.sh            编译 + ad-hoc 签名 + 输出 DockClickMin.app 到当前目录
#   ./build.sh run        编译后启动
#   ./build.sh diagnose   编译后跑一次诊断（打印 Dock 图标矩形）
set -euo pipefail
cd "$(dirname "$0")"

APP="DockClickMin"
STAGE="/tmp/dockclickmin-build"
SDK_TARGET_MIN="13.0"

rm -rf "$STAGE"
mkdir -p "$STAGE/$APP.app/Contents/MacOS"
mkdir -p "$STAGE/$APP.app/Contents/Resources"

cp Info.plist "$STAGE/$APP.app/Contents/Info.plist"
printf 'APPL????' > "$STAGE/$APP.app/Contents/PkgInfo"

echo "==> 编译 x86_64"
swiftc -O -swift-version 5 -target "x86_64-apple-macos${SDK_TARGET_MIN}" \
    -o "$STAGE/x86_64" main.swift \
    -framework Cocoa -framework ApplicationServices

echo "==> 编译 arm64"
swiftc -O -swift-version 5 -target "arm64-apple-macos${SDK_TARGET_MIN}" \
    -o "$STAGE/arm64" main.swift \
    -framework Cocoa -framework ApplicationServices

echo "==> 合成通用二进制"
lipo -create "$STAGE/x86_64" "$STAGE/arm64" -output "$STAGE/$APP.app/Contents/MacOS/$APP"
lipo -info "$STAGE/$APP.app/Contents/MacOS/$APP"

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$STAGE/$APP.app"
codesign -dv "$STAGE/$APP.app" 2>&1 | sed -n '1,6p'

echo "==> 拷回工作区（去扩展属性）"
rm -rf "$APP.app"
ditto --norsrc --noextattr "$STAGE/$APP.app" "$PWD/$APP.app"
xattr -cr "$APP.app" 2>/dev/null || true

echo "OK: $PWD/$APP.app"

case "${1:-}" in
  run)
    open "$PWD/$APP.app"
    echo "已启动（菜单栏图标 dock.rectangle）"
    ;;
  diagnose)
    "$PWD/$APP.app/Contents/MacOS/$APP" --diagnose
    ;;
esac
