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
