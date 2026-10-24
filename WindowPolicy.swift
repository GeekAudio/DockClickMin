import Foundation

enum CollapseMode: String {
    case hide
    case minimize
}

/// 保留用户所选动画；兼容应用只用应用自己的原生窗口命令。
enum WindowPolicy {
    static func protectedApps(configured: [String]?) -> Set<String> {
        Set(configured ?? [])
    }

    static func migratedProtectedApps(_ configured: [String]?) -> [String] {
        (configured ?? []).filter { $0 != "com.apple.finder" && $0 != "com.tencent.qq" }
    }

    static func nativeHideApps(configured: [String]?) -> Set<String> {
        Set(configured ?? [])
    }

    static func nativeMinimizeApps(configured: [String]?) -> Set<String> {
        Set(configured ?? []).union(["com.tencent.qq"])
    }

    static func effectiveMode(bundleID: String?, requested: CollapseMode,
                              nativeHideApps: Set<String>) -> CollapseMode {
        if let bundleID = bundleID, nativeHideApps.contains(bundleID) { return .hide }
        return requested
    }

    static func shouldCollapse(isFrontAtMouseDown: Bool, wasHidden: Bool,
                               windowCount: Int, minimizedCount: Int,
                               hasVisibleWindow: Bool) -> Bool {
        guard isFrontAtMouseDown, !wasHidden else { return false }
        if windowCount > 0 { return minimizedCount < windowCount }
        // AX 未实现窗口枚举的应用，仍可通过系统窗口列表识别后隐藏。
        return hasVisibleWindow
    }
}
