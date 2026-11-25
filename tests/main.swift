import Foundation

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    guard condition() else { fatalError("FAIL \(name)") }
    print("PASS \(name)")
}

check("默认不排除任何应用", WindowPolicy.protectedApps(configured: nil).isEmpty)
check("保留用户自定义排除", WindowPolicy.protectedApps(configured: ["com.example.editor"]) == ["com.example.editor"])
check("旧默认名单迁移恢复QQ/访达", WindowPolicy.migratedProtectedApps(["com.apple.finder", "com.tencent.qq"]).isEmpty)
check("迁移保留其他自定义项", WindowPolicy.migratedProtectedApps(["com.tencent.qq", "com.example.editor"]) == ["com.example.editor"])

let nativeApps = WindowPolicy.nativeHideApps(configured: nil)
check("默认不取消任何应用的动画", nativeApps.isEmpty)
check("QQ始终采用原生最小化命令", WindowPolicy.nativeMinimizeApps(configured: ["com.example.editor"]) == ["com.example.editor", "com.tencent.qq"])
check("QQ最小化模式保留动画", WindowPolicy.effectiveMode(bundleID: "com.tencent.qq", requested: .minimize, nativeHideApps: nativeApps) == .minimize)
check("QQ隐藏模式保持隐藏", WindowPolicy.effectiveMode(bundleID: "com.tencent.qq", requested: .hide, nativeHideApps: nativeApps) == .hide)
check("访达仍支持最小化", WindowPolicy.effectiveMode(bundleID: "com.apple.finder", requested: .minimize, nativeHideApps: nativeApps) == .minimize)
check("普通应用保持用户选择", WindowPolicy.effectiveMode(bundleID: "com.example.editor", requested: .hide, nativeHideApps: nativeApps) == .hide)
check("其他应用可加入兼容策略", WindowPolicy.effectiveMode(bundleID: "com.example.editor", requested: .minimize, nativeHideApps: ["com.example.editor"]) == .hide)

check("前台可见窗口点击收起", WindowPolicy.shouldCollapse(isFrontAtMouseDown: true, wasHidden: false, windowCount: 1, minimizedCount: 0, hasVisibleWindow: true))
check("隐藏窗口点击恢复而不重新收起", !WindowPolicy.shouldCollapse(isFrontAtMouseDown: true, wasHidden: true, windowCount: 1, minimizedCount: 0, hasVisibleWindow: true))
check("后台窗口点击唤出而不立即收起", !WindowPolicy.shouldCollapse(isFrontAtMouseDown: false, wasHidden: false, windowCount: 1, minimizedCount: 0, hasVisibleWindow: true))
check("最小化窗口点击恢复", !WindowPolicy.shouldCollapse(isFrontAtMouseDown: true, wasHidden: false, windowCount: 1, minimizedCount: 1, hasVisibleWindow: false))
check("未实现AX窗口列表仍可隐藏", WindowPolicy.shouldCollapse(isFrontAtMouseDown: true, wasHidden: false, windowCount: 0, minimizedCount: 0, hasVisibleWindow: true))
check("没有任何窗口时放行原生打开", !WindowPolicy.shouldCollapse(isFrontAtMouseDown: true, wasHidden: false, windowCount: 0, minimizedCount: 0, hasVisibleWindow: false))
check("按下时不可见的前台应用交给 Dock 恢复",
      !WindowPolicy.shouldCollapse(isFrontAtMouseDown: true, wasHidden: false, windowCount: 1,
                                   minimizedCount: 0, hasVisibleWindow: true, wasVisibleAtMouseDown: false))

var collapse = WindowClickIntent(target: .collapsed)
check("单击由原有收起路径执行", collapse.followUp(observed: .visible, isFrontmost: true) == nil)
collapse.reverse()
check("收起途中第二击请求原生恢复", collapse.followUp(observed: .collapsed, isFrontmost: false) == .visible)
check("窗口已经可见时不重复恢复", collapse.followUp(observed: .visible, isFrontmost: true) == nil)
collapse.reverse()
check("收起途中第三击保留收起目标", collapse.target == .collapsed && collapse.revision == 2)
check("三击期间已有最小化时不重复收起", collapse.followUp(observed: .collapsed, isFrontmost: true) == nil)
check("前一次收起已取消时按第三击重新收起", collapse.followUp(observed: .visible, isFrontmost: true) == .collapsed)

var restore = WindowClickIntent(target: .visible)
restore.reverse()
check("恢复途中第二击在窗口可见后收起", restore.followUp(observed: .visible, isFrontmost: true) == .collapsed)
check("等待 Dock 恢复前台焦点", restore.followUp(observed: .visible, isFrontmost: false) == nil)
check("窗口状态未知时等待", restore.followUp(observed: nil, isFrontmost: true) == nil)

var early = WindowClickIntent()
early.reverse()
check("异步窗口判定前先记住第二击", early.target == nil && early.revision == 1)
early.begin(target: .collapsed)
check("初始收起判定后应用提前到达的第二击", early.target == .visible)
check("应用仍有可见窗口时也恢复本次收起的其他窗口",
      early.followUp(observed: .visible, isFrontmost: true, hasWindowsToRestore: true) == .visible)
