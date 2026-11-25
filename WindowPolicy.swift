import Foundation

enum CollapseMode: String {
    case hide
    case minimize
}

enum WindowVisibility {
    case visible
    case collapsed
}

struct WindowClickIntent {
    private var initialTarget: WindowVisibility?
    private(set) var revision = 0

    init(target: WindowVisibility? = nil) {
        initialTarget = target
    }

    var target: WindowVisibility? {
        guard let initialTarget else { return nil }
        if revision.isMultiple(of: 2) { return initialTarget }
        return initialTarget == .visible ? .collapsed : .visible
    }

    mutating func begin(target: WindowVisibility) {
        initialTarget = target
    }

    mutating func reverse() {
        revision += 1
    }

    func followUp(observed: WindowVisibility?, isFrontmost: Bool,
                  hasWindowsToRestore: Bool = false) -> WindowVisibility? {
        guard revision > 0, let observed, let target else { return nil }
        switch target {
        case .visible:
            return observed == .collapsed || hasWindowsToRestore ? .visible : nil
        case .collapsed:
            return observed == .visible && isFrontmost ? .collapsed : nil
        }
    }
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
                               hasVisibleWindow: Bool, wasVisibleAtMouseDown: Bool? = nil) -> Bool {
        guard isFrontAtMouseDown, !wasHidden, wasVisibleAtMouseDown != false else { return false }
        if windowCount > 0 { return minimizedCount < windowCount }
        // AX 未实现窗口枚举的应用，仍可通过系统窗口列表识别后隐藏。
        return hasVisibleWindow
    }
}
