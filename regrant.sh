#!/bin/bash
# 重新授权（重编译后必跑：ad-hoc 签名的 cdhash 变了，旧授权立即失效）
# 用法：在「终端」里执行  ./regrant.sh
set -euo pipefail
cd "$(dirname "$0")"

BID="com.geekaudio.DockClickMin"

echo "==> 停掉旧实例"
pkill -f "DockClickMin.app/Contents/MacOS/DockClickMin" 2>/dev/null || true
sleep 1

echo "==> 清掉旧的辅助功能记录"
tccutil reset Accessibility "$BID" || echo "（tccutil 失败也没关系，下面手动关掉再打开即可）"

echo "==> 启动"
open "$PWD/DockClickMin.app"

cat <<'TIP'

--------------------------------------------------------------
接下来在系统设置里操作一次：
  系统设置 › 隐私与安全性 › 辅助功能
  找到 DockClickMin → 把开关 关掉 → 再打开
（如果列表里没有它，点「+」把 DockClickMin.app 拖进去）

然后菜单栏点一下 dock.rectangle 图标，确认状态显示「监听中 · N 个图标」。
--------------------------------------------------------------
TIP
