// QQ 原生最小化/恢复对照，不读取窗口标题或聊天内容。
import Cocoa
import ApplicationServices

guard AXIsProcessTrusted(),
      let qq = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.qq").first else {
    fatalError("需要辅助功能权限和运行中的 QQ")
}
let previousFront = NSWorkspace.shared.frontmostApplication
let pid = qq.processIdentifier
func spin(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
    return value
}
func windows() -> [AXUIElement] {
    (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute as String) as? [AXUIElement] ?? [])
        .filter { attribute($0, kAXRoleAttribute as String) as? String == kAXWindowRole as String }
}
func minimizedCount() -> Int { windows().filter { attribute($0, kAXMinimizedAttribute as String) as? Bool == true }.count }
func layers() -> [Int] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return list.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let b = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
              rect.width > 40, rect.height > 40 else { return nil }
        return window[kCGWindowLayer as String] as? Int
    }
}
func dockItem(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 6 else { return nil }
    if let url = attribute(el, kAXURLAttribute as String) as? NSURL,
       Bundle(url: url as URL)?.bundleIdentifier == "com.tencent.qq" { return el }
    for child in attribute(el, kAXChildrenAttribute as String) as? [AXUIElement] ?? [] {
        if let item = dockItem(child, depth: depth + 1) { return item }
    }
    return nil
}
func restoreViaDock() {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
          let item = dockItem(AXUIElementCreateApplication(dock.processIdentifier)) else { fatalError("找不到 QQ Dock 图标") }
    print("Dock press:", AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)
    spin(1.0)
}
func minimizeMenu(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 6 else { return nil }
    if (attribute(el, kAXMenuItemCmdCharAttribute as String) as? String)?.lowercased() == "m",
       (attribute(el, kAXMenuItemCmdModifiersAttribute as String) as? NSNumber)?.intValue == 0 {
        return el
    }
    for child in attribute(el, kAXChildrenAttribute as String) as? [AXUIElement] ?? [] {
        if let found = minimizeMenu(child, depth: depth + 1) { return found }
    }
    return nil
}

qq.unhide()
qq.activate(options: [])
spin(0.4)
print("baseline:", layers(), "minimized:", minimizedCount())
let source = CGEventSource(stateID: .hidSystemState)
var allPassed = true
for cycle in 1...5 {
    qq.activate(options: [])
    spin(0.2)
    let app = AXUIElementCreateApplication(pid)
    var pressed = false
    if let bar = attribute(app, kAXMenuBarAttribute as String),
       let menu = minimizeMenu(unsafeBitCast(bar, to: AXUIElement.self)) {
        let result = AXUIElementPerformAction(menu, kAXPressAction as CFString)
        print("Minimize menu press:", result.rawValue)
        pressed = result == .success
    }
    if !pressed {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x2E, keyDown: down)!
            event.flags = .maskCommand
            event.postToPid(pid)
        }
    }
    spin(0.8)
    let collapsed = minimizedCount() > 0
    print("cycle", cycle, "after native minimize:", layers(), "minimized:", minimizedCount())
    restoreViaDock()
    spin(1.0)
    let restored = minimizedCount() == 0
    let normal = !layers().isEmpty && layers().allSatisfy { $0 == 0 }
    print(collapsed && restored && normal ? "PASS" : "FAIL", "cycle", cycle,
          "after native Dock restore:", layers(), "minimized:", minimizedCount())
    if !collapsed || !restored || !normal { allPassed = false; break }
}
if let previousFront = previousFront, previousFront.processIdentifier != pid { previousFront.activate(options: []) }
exit(allPassed ? 0 : 2)
