#!/bin/bash
# 把 DockClickMin.app 装到 /Applications（别人的机器上也一样用这个脚本，或直接拖拽）
#   ./install.sh          安装并启动
#   ./install.sh --force  已存在时先退出旧实例再覆盖
set -euo pipefail
cd "$(dirname "$0")"

SRC="$PWD/DockClickMin.app"
DEST="/Applications/DockClickMin.app"

[ -d "$SRC" ] || { echo "找不到 $SRC，先跑 ./build.sh"; exit 1; }

if [ -d "$DEST" ]; then
    if [ "${1:-}" != "--force" ]; then
        echo "已存在 $DEST"
        echo "要覆盖请加 --force（会先退出正在运行的实例）"
        exit 0
    fi
    echo "==> 退出正在运行的实例"
    pkill -x DockClickMin 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
fi

echo "==> 拷贝到 /Applications（去扩展属性，避免签名/权限异常）"
ditto --norsrc --noextattr "$SRC" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true

echo "==> 校验签名"
codesign -dv "$DEST" 2>&1 | grep -E "Identifier|Signature" || true

echo "==> 启动"
open "$DEST"

cat <<'TIP'

--------------------------------------------------------------
装好了：/Applications/DockClickMin.app

如果这是第一次在这台机器上运行，还要走两步：
  1. 首次打开被 Gatekeeper 拦：
     双击被拦 → 点「完成」→ 系统设置 › 隐私与安全性 › 安全性
     → 点「仍要打开」→ 输密码 → 再点「打开」
  2. 弹「想要控制这台电脑」→ 系统设置 › 隐私与安全性 › 辅助功能
     → 打开 DockClickMin 的开关（等 2 秒自动生效，不用重启）

菜单栏出现 dock 图标、状态显示「监听中 · N 个图标」即成功。
开机自启默认开启，写的是 ~/Library/LaunchAgents/com.geekaudio.DockClickMin.plist
--------------------------------------------------------------
TIP
