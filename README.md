# DockClickMin

<img src="assets/icon-1024.png" width="120" align="right">

> 点 Dock 图标 = 收起前台应用（Windows 任务栏语义），macOS 原生实现。
> Click a Dock icon to collapse the frontmost app — pure Cocoa / Accessibility / CGEventTap, no third-party dependency.

菜单栏常驻，无 Dock 图标。点一下收起，再点一下还原；QQ 使用应用自身的最小化命令，保留系统最小化动画。

## 1.0.8

换了个低饱和的扁平图标，还是熟悉的箭头。QQ 保留原生最小化动画，恢复时不再额外提到最前；访达也恢复点击收起支持。

## 最小化兼容修复

统一收起/恢复逻辑，默认不再排除 QQ 或访达。在最小化模式下，QQ 只调用应用自身的「最小化」菜单或定向发送 ⌘M，等待实际最小化结果并按需重试，保留系统动画；恢复全部交给原生 Dock。QQ 不按 `AXMinimizeButton`、不写 `AXMinimized`，也不额外执行 `AXRaise`。

其他应用优先使用所选的全局收起方式，最小化失败时回退到隐藏。`hide()` 返回 `false` 也可能已经触发隐藏，因此会等待并验证结果，再决定是否回退；发送全局 ⌘H 前还会确认目标仍在前台，避免误隐藏已切换到的应用。

保护名单 `protectedApps` 和原生隐藏名单 `nativeHideApps` 默认均为空；原生最小化名单 `nativeMinimizeApps` 始终包含 QQ，可添加其他应用。升级后首次启动执行兼容策略 v3 迁移：移除保护名单中原来的默认项访达和 QQ，移除 QQ 旧的原生隐藏策略，保留其他自定义项。同时清理跨点击残留的待提到前台状态，避免后续点击触发上一次点击留下的动作。不同应用对系统接口的支持仍有差异，实际效果以日志和实际操作验证为准。

---

## 为什么必须自己写

macOS **没有**这个开关。点 Dock 图标只有两个语义：把 app 激活到前台；已在前台则什么都不做。系统设置里唯一相关的是 `minimize-to-application`（窗口最小化后飞进图标），那是「窗口去哪」，不是「点图标收起」。

纯 app 内的 `applicationShouldHandleReopen(_:hasVisibleWindows:)` 也不行 —— **app 已在前台时 Dock 根本不发 `rapp` 事件**，回调不会被调用。所以只能从系统层监听点击。

## 原理

```
Dock 进程 AX 树 ──► 每个应用图标的实时矩形 + bundle id
                          │
CGEventTap(左键 down/up) ─┴─► 按下：记住当时的前台 pid
                              抬起：落点仍在同一图标内 && 该 app 就是当时的前台
                                    └─► 收起它
```

三个关键设计：

1. **保留普通点击的原生事件**：`CGEvent.tapCreate(options: .defaultTap)`，普通应用点击原样放行；仅在点击已打开的启动台图标、需要关闭启动台时吞掉这一组点击。带修饰键的点击（含 ⌥-click 隐藏其他）全部放行。
2. **命中判定用 Dock 的 AX 树**，不是硬编码坐标。放大动画、图标增减、换位置都自动跟随。
3. **1 秒刷新的矩形缓存**做廉价过滤，命中后才做精确 AX 查询，避免每次点击都付 IPC 成本。

## 安装

### 方式一：下载 DMG

从 [Releases](../../releases) 下载 `DockClickMin-<version>.dmg`，打开后把 `DockClickMin.app` 拖到旁边的 `Applications` 快捷方式。

DMG 里还有一份 `使用说明.html`（不含下载链接，适合随包分发）：双击即可看安装、菜单、常见问题。

首次打开会被 Gatekeeper 拦（ad-hoc 签名）：

> 双击被拦 → 点「完成」→ **系统设置 › 隐私与安全性 › 安全性** → 点「仍要打开」→ 输密码 → 再点「打开」

> macOS 15 Sequoia 起「右键 → 打开」这条绕过通道已被 Apple 移除，弹窗里不会再有「打开」按钮。

### 方式二：自己编译

```bash
git clone https://github.com/GeekAudio/DockClickMin.git
cd DockClickMin
./build.sh            # 编译 + ad-hoc 签名
./install.sh          # 拷到 /Applications 并启动（已存在则加 --force）
```

需要 Xcode Command Line Tools（`xcode-select --install`）。产物是通用二进制（x86_64 + arm64）。

> 建议装到 `/Applications`：工作区里的那份是开发副本，`./build.sh` 每次都会覆盖它；装到 `/Applications` 后开机自启、Finder 里双击、辅助功能列表里的条目都指向同一个位置。

### 授权（两种方式都要做）

首次启动会弹「DockClickMin 想要控制这台电脑」，点 **打开系统设置** →
**隐私与安全性 › 辅助功能** → 打开 DockClickMin 的开关。

授权后菜单栏出现 `dock.rectangle` 图标，菜单里状态显示「监听中 · N 个图标」。

> 授权生效后**不需要手动重启**：程序每 2 秒复查一次权限，一旦通过就自动建立监听（`AXIsProcessTrusted` 的结果会被进程缓存，早期版本必须重启进程才认）。

## 菜单

菜单顶部只在**你勾了「启用」却没授权**时才提示权限；手动关掉开关时只说「已停用」，不会满屏「未授权」。



| 项 | 作用 |
|---|---|
| 启用 | 总开关，关掉后事件监听停止 |
| 开机自启 | 登录时自动启动，**默认开**（详见下文） |
| 唤出时提到最前 | 点 Dock 图标唤出应用后，用 `AXRaise` 把它的主窗口提到最前，**默认开**；原生最小化名单、原生隐藏名单和保护名单中的应用除外 |
| 收起方式：最小化优先（不兼容时隐藏） | 普通应用按黄色按钮 / ⌘M，支持时使用系统动画（**默认**）；QQ 只用应用自身的最小化菜单 / 定向 ⌘M |
| 收起方式：隐藏整个应用（瞬时，无动画） | `NSRunningApplication.hide()`，像 ⌘H |
| 状态：监听中 · N 个图标 | 实时确认 AX 枚举是否正常 |
| 状态：已停用 | 手动关掉了「启用」，此时不提示权限问题 |
| 打开日志 | `~/Library/Logs/DockClickMin.log` |
| 退出 | 终止 |

## 收起方式

| 方式 | 实现 | 动画 |
|---|---|---|
| **最小化窗口**（默认） | 三级最小化回退，每级验证结果，失败后尝试隐藏 | ✅ 前两级有 |
| 隐藏整个应用 | 尝试隐藏并验证实际结果 | ❌ 瞬时 |
| 原生最小化名单（始终含 QQ） | 最小化模式下只调用应用自身的最小化菜单 / 定向 ⌘M | ✅ 保留系统动画 |
| 原生隐藏名单（默认空） | 优先于全局方式，只使用原生隐藏途径 | ❌ 瞬时 |

**为什么隐藏也要验证**：`NSRunningApplication.hide()` 的返回值不能代替最终状态。部分应用会返回 `false`，随后仍完成隐藏；因此需要等待并检查，确认未隐藏后才尝试下一步。全局 ⌘H 只在目标仍是前台应用时发送。

QQ 的最小化路径为：应用自身的「最小化」菜单 / 定向 ⌘M → 等待并检查实际最小化状态 → 必要时重试。此路径不按 `AXMinimizeButton`、不写 `AXMinimized`，恢复时也不额外执行 `AXRaise`。动画样式跟随系统设置，使用 genie 时保留飞入 Dock 的效果。原生命令最终未成功时只记录失败，不把 QQ 改成无动画隐藏。其他应用保留所选全局方式及相应回退，日志记录各步结果。

普通应用的三级回退（`minimizeAll`，原生最小化名单除外）：

| 级 | 动作 | 说明 |
|---|---|---|
| ① | 按窗口自己的 `AXMinimizeButton` | 与手点黄色按钮等价，genie 动画 |
| ② | `CGEvent.postToPid` 发 ⌘M | 走 app 自己的「窗口 › 最小化」菜单命令，也有动画 |
| ③ | 直接置 `AXMinimized = true` | 最后兜底，无动画 |

**窗口列表要过滤**：`kAXWindowsAttribute` 会混进非窗口元素 —— 访达会把桌面滚动区（`AXScrollArea`）也塞进窗口列表，它没有最小化按钮、永远收不起来。不过滤的话统计会卡在 `1/2`，还会反复重试。所以取窗口时按 `role == AXWindow` 过滤。

**为什么需要三级**：AX 的 `.success` 只代表「消息投递成功」，不代表 app 照做。某些应用可能返回成功但窗口不动，只写 ① 的话点了仍没反应。日志会打印每级的实际效果，例如：

```
收起 示例应用：按钮 1 成功→0/1 / ⌘M 1 次→1/1 / 起始 0/1
```

最小化动画样式跟随系统设置 › 桌面与程序坞 ›「最小化窗口使用」：

```bash
defaults read com.apple.dock mineffect          # genie | scale
defaults write com.apple.dock mineffect -string genie && killall Dock
```

## 点第二下会恢复

窗口已全部最小化时，本工具**主动放行**（`stats.minimized == stats.total` 直接 return），于是系统原生的「点图标恢复所有窗口」照常工作。隐藏后的应用也由系统原生 Dock 唤回。恢复窗口本身由系统完成，不通过 AX 修改最小化状态。QQ 使用应用自身的最小化命令保留动画，点第二下同样交给 Dock 原生恢复，不再走实验性的 AX 恢复，也不会额外执行 `AXRaise`。

## 启动台（Apps / Launchpad）

macOS 26 Tahoe 把启动台换成了 `/System/Applications/Apps.app`（`com.apple.apps.launcher`，`LSUIElement`）。它不是普通 app —— 没有「最小化」语义，点图标应当是**关闭**它。

所以这一格走单独分支：启动台已打开时，吞掉这次图标点击，先用 Docklet 开关通知和切换前台应用关闭覆盖层，必要时再尝试 Esc。启动台关闭时点击图标，仍由原生 Dock 打开。

注意：`open -b com.apple.apps.launcher` **打不开它**（只能由 Dock 图标唤起），所以这一条只能靠真实点击验证。

## 边界与已知行为

| 场景 | 行为 | 原因 |
|---|---|---|
| 点**非**前台的 Dock 图标 | 正常切换，不收起 | 按下时的前台 pid ≠ 图标 pid |
| 窗口已全部最小化时点图标 | **原生恢复所有窗口** | 主动放行，不抢系统行为 |
| 点**启动台**图标且它正开着 | 吞掉这次点击并关闭覆盖层 | 启动器没有最小化语义 |
| 点前台**访达**图标 | 按所选全局方式收起，最小化失败时尝试隐藏 | 默认不再排除访达 |
| 点前台 **QQ** 图标 | 最小化模式下用应用自身的最小化菜单 / 定向 ⌘M，保留动画；再次点击由 Dock 原生恢复 | 始终在原生最小化名单中，不按 AX 最小化按钮、不写 `AXMinimized`、不额外执行 `AXRaise` |
| 按住 ⌘/⌥/⌃/⇧ 点 | 完全放行 | 保留 ⌥-click 隐藏其他等原生操作 |
| 图标内按下后拖拽（≥8pt） | 不触发 | 防止拖拽排序图标时误收起 |
| app 一个窗口都没有 | 放行，走原生「打开新窗口」 | 否则会把「重新打开窗口」吃掉 |
| 有对话框/无标题窗口 | 普通应用可能退回置 `AXMinimized`（无动画）；QQ 等原生最小化名单中的应用只尝试自身菜单 / ⌘M | 应用提供的最小化接口不同 |
| Dock 自动隐藏 | 鼠标探出后约 1 秒内可能不响应 | 矩形缓存 1s 刷新，Dock 未升起时图标坐标在屏幕外 |
| 多显示器 | 支持 | 全程用全局屏幕坐标，不做屏幕假设 |
| 唤出时提到最前 | 对普通应用有效，**压不过其他浮动层级窗口** | `AXRaise` 只能越过同层级窗口；原生最小化名单、原生隐藏名单和保护名单中的应用不会执行此动作 |

> 关于「QQ 一直置顶，别的程序盖不住」：旧版本存在直接修改 QQ 最小化状态的路径。1.0.7 改用 QQ 自身的最小化菜单 / 定向 ⌘M，并将恢复交给 Dock，保留最小化动画，同时移除对 QQ 的 AX 最小化按钮、最小化属性和额外提到最前操作。现有验证不足以保证这一调整能消除所有置顶原因，原生命令也可能暂时不响应；日志会记录实际结果。若 QQ 当前仍保持置顶，可在方便时退出 QQ 后重新打开。

## 保护名单

`protectedApps` 默认为空，所有应用都参与统一收起/恢复逻辑。可以自行添加应用，将它们的 Dock 点击完全交给系统：不收起、不执行 AX 恢复或 `AXRaise`。升级后首次启动迁移旧配置，会移除过去默认加入的访达和 QQ，保留其他自定义项；迁移后仍可按自己的需要将它们加入排除名单。

想添加其他受保护应用，不必重新编译：

```bash
# 添加需要完全排除的应用 bundle id
defaults write com.geekaudio.DockClickMin protectedApps -array com.example.app

# 查看自定义名单
defaults read com.geekaudio.DockClickMin protectedApps

# 清空排除名单
defaults write com.geekaudio.DockClickMin protectedApps -array
```

> `-array` 是**整体覆盖保存的自定义名单**，必须把要保留的其他应用一起写进去。

## 原生最小化名单

`nativeMinimizeApps` 始终包含 **QQ**（`com.tencent.qq`）。最小化模式下，名单中的应用只通过自身的「最小化」菜单 / 定向 ⌘M 收起，等待结果并按需重试，保留系统动画；不按 `AXMinimizeButton`、不写 `AXMinimized`，也不额外执行 `AXRaise`。再次点击图标由原生 Dock 恢复。

可以把有类似窗口兼容性问题的应用加入名单。添加其他应用或覆盖自定义设置时，实际生效的名单仍包含 QQ。保护名单优先；选择全局隐藏模式，或自行将应用加入原生隐藏名单时，会按隐藏方式收起。

```bash
defaults read com.geekaudio.DockClickMin nativeMinimizeApps
# 添加其他应用；实际生效的名单始终包含 QQ
defaults write com.geekaudio.DockClickMin nativeMinimizeApps -array com.example.app
```

## 原生隐藏名单

`nativeHideApps` 默认为空，可自行添加希望通过隐藏收起的应用。名单中的应用忽略全局收起方式，通过 `NSRunningApplication.hide()`、应用自身的隐藏菜单 / 定向 ⌘H 收起，并验证隐藏结果；不会写 `AXMinimized`、`AXHidden` 或执行 `AXRaise`。再次点击图标由原生 Dock 唤回，没有最小化动画。

兼容策略 v3 迁移会移除旧设置中的 QQ 隐藏项，恢复它的原生最小化路径，保留其他自定义隐藏项。保护名单优先：若同一应用同时出现在保护名单中，将完全放行。

```bash
defaults read com.geekaudio.DockClickMin nativeHideApps
# 添加希望固定通过隐藏收起的应用
defaults write com.geekaudio.DockClickMin nativeHideApps -array com.example.app
```

## 温和名单

`gentleApps` 为兼容保留的自定义名单，默认设置为空，实际生效时合并原生最小化名单（因此始终包含 QQ）。名单里的应用通过自身最小化菜单 / 定向 ⌘M 收起，不按 AX 黄色按钮、也不直接置 `AXMinimized`。

这适合希望通过应用自身「最小化」菜单命令收起的场景。保护名单、原生隐藏名单优先。新设置建议使用上面的 `nativeMinimizeApps`。

```bash
defaults read  com.geekaudio.DockClickMin gentleApps
defaults write com.geekaudio.DockClickMin gentleApps -array com.example.app   # 整体覆盖
```

若想让某个应用彻底交给原生 Dock，可将其加入保护名单：

```bash
defaults write com.geekaudio.DockClickMin protectedApps -array com.example.app
```

## 重编译会掉授权

ad-hoc 签名没有稳定身份，TCC 记录的是 **cdhash**。每次 `./build.sh` 后 cdhash 变化，旧授权立即失效。实测证据：

```bash
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select hex(csreq) from access where client='com.geekaudio.DockClickMin' \
   and service='kTCCServiceAccessibility';" | xxd -r -p > /tmp/c.bin
csreq -r /tmp/c.bin -t
#   cdhash H"83b7776a..." or cdhash H"c166ca8a..."   ← 旧二进制
codesign -d --verbose=4 DockClickMin.app 2>&1 | grep ^CDHash
#   CDHash=078f2ebd...                               ← 新二进制，不在列表里 ⇒ 拒绝
```

改完代码后：

```bash
./regrant.sh     # 重置授权 + 启动，然后在系统设置里把开关关掉再打开
```

想彻底免掉这一步，用自签名证书签名（designated requirement 与 cdhash 解耦）。

## 诊断

```bash
# 直接跑二进制拿不到授权（TCC 把调用方认成父进程），必须走 LaunchServices
open -n ./DockClickMin.app --args --diagnose      # 结果写日志

# 窗口结构 dump：逐个 app 打印 title/role/subrole/min/frame/有无最小化按钮
touch ~/Library/Logs/DockClickMin.dump && open ./DockClickMin.app

# 自测：走完整判定链（onDown → onUp → 收起），不需要真的点鼠标
touch ~/Library/Logs/DockClickMin.selftest && open ./DockClickMin.app

tail -30 ~/Library/Logs/DockClickMin.log
```

## 开机自启（内置，默认开启）

菜单栏 → **开机自启**，默认勾选。实现是写一个 LaunchAgent，登录时 launchd 自动加载，不需要 root，也不要求 app 装在 `/Applications`：

```
~/Library/LaunchAgents/com.geekaudio.DockClickMin.plist
```

每次启动都会按当前可执行文件路径重写这个 plist —— app 被移动、改名后能自愈，不会留下失效的路径。

- 取消勾选 ⇒ `launchctl bootout` + 删除 plist
- 单实例保护：launchd 与手动 `open` 同时拉起时只保留一个进程

手动检查：

```bash
plutil -p ~/Library/LaunchAgents/com.geekaudio.DockClickMin.plist
launchctl list | grep DockClickMin
```

## 卸载

```bash
launchctl bootout gui/$(id -u)/com.geekaudio.DockClickMin 2>/dev/null
rm -f ~/Library/LaunchAgents/com.geekaudio.DockClickMin.plist
rm -rf /Applications/DockClickMin.app ~/Library/Logs/DockClickMin.log
defaults delete com.geekaudio.DockClickMin 2>/dev/null
```

## 只给自己的 app 加这个功能？

不需要本工具，但**只在「app 不在前台时点图标」生效**：

```swift
func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard flag else { return true }
    for w in NSApp.windows where w.isVisible && !w.isMiniaturized && w.canBecomeMain {
        w.miniaturize(nil)      // 或 NSApp.hide(nil) 整个 app 收起
    }
    return false
}
```

要「已在前台也能收起」，就必须像本工具一样上 CGEventTap + AX，代价是辅助功能授权 + 常驻进程。

## 实测环境

macOS 26.7.1（25G241）/ Intel i7-12700K / 双屏。理论支持 macOS 13+，未在 Apple Silicon 上验证（代码是通用二进制，arm64 切片可运行）。

## License

MIT
