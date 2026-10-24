// 实机验证：swift tests/native-hide-smoke.swift com.tencent.qq 5
// 不需要辅助功能权限；只调用原生隐藏/恢复，并检查真实窗口层级。
import Cocoa

let arguments = CommandLine.arguments
guard arguments.count > 1,
      let target = NSRunningApplication.runningApplications(withBundleIdentifier: arguments[1]).first else {
    fatalError("请指定正在运行的应用 bundle id")
}
let cycles = arguments.count > 2 ? Int(arguments[2]) ?? 5 : 5
let originalFront = NSWorkspace.shared.frontmostApplication
let originallyHidden = target.isHidden

func waitFor(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(1.5)
    repeat {
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        if condition() { return true }
    } while Date() < deadline
    return condition()
}

func windowLayers() -> Set<Int> {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return Set(windows.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? pid_t) == target.processIdentifier,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              rect.width > 40, rect.height > 40 else { return nil }
        return window[kCGWindowLayer as String] as? Int
    })
}

target.unhide()
target.activate(options: [])
guard waitFor({ !target.isHidden && target.isActive }) else { fatalError("无法激活目标应用") }
let baseline = windowLayers()
var passed = !baseline.isEmpty
for cycle in 1...max(1, cycles) {
    let request = target.hide()
    let hidden = waitFor { target.isHidden }
    target.unhide()
    target.activate(options: [])
    let restored = waitFor { !target.isHidden && target.isActive && !windowLayers().isEmpty }
    let layers = windowLayers()
    let stable = layers.subtracting(baseline).isEmpty
    passed = passed && hidden && restored && stable
    print("\(hidden && restored && stable ? "PASS" : "FAIL") cycle=\(cycle) hideRequest=\(request) hidden=\(hidden) restored=\(restored) layers=\(layers.sorted())")
}

if originallyHidden {
    target.hide()
    _ = waitFor { target.isHidden }
}
if let originalFront = originalFront, originalFront.processIdentifier != target.processIdentifier {
    originalFront.activate(options: [])
    _ = waitFor { originalFront.isActive }
}
exit(passed ? 0 : 2)
