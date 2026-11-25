// Validate DockClickMin with real system-level mouse events.
//
// Run from the repository root after arranging a disposable, visible Finder
// window in front:
//   swift tests/dock-click-interruption-smoke.swift
//   swift tests/dock-click-interruption-smoke.swift --bundle-id com.apple.finder --interval-ms 100
//
// The script never launches or activates an app. It temporarily minimizes and
// restores all windows belonging to the selected app. Finder is the default.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

var recoveryAction: (() -> Void)?

struct Options {
    var bundleID = "com.apple.finder"
    var intervalMilliseconds = 100
}

struct WindowState {
    let total: Int
    let minimized: Int
    let visibleOnScreen: Bool

    var isFullyMinimized: Bool {
        total > 0 && minimized == total
    }

    var isRestored: Bool {
        total > 0 && minimized == 0 && visibleOnScreen
    }
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    recoveryAction?()
    recoveryAction = nil
    fputs("FAIL \(message)\n", stderr)
    exit(code)
}

func parseOptions() -> Options {
    var options = Options()
    var index = 1
    while index < CommandLine.arguments.count {
        let argument = CommandLine.arguments[index]
        switch argument {
        case "--bundle-id":
            index += 1
            guard index < CommandLine.arguments.count else {
                fail("--bundle-id 需要一个 bundle identifier")
            }
            options.bundleID = CommandLine.arguments[index]
        case "--interval-ms":
            index += 1
            guard index < CommandLine.arguments.count,
                  let value = Int(CommandLine.arguments[index]), (20...1000).contains(value) else {
                fail("--interval-ms 必须是 20 到 1000 之间的整数")
            }
            options.intervalMilliseconds = value
        case "--help", "-h":
            print("用法：swift tests/dock-click-interruption-smoke.swift [--bundle-id ID] [--interval-ms N]")
            print("默认测试已在前台且有可见窗口的 Finder，快速双击间隔为 100 ms。")
            exit(0)
        default:
            fail("未知参数：\(argument)。使用 --help 查看用法。")
        }
        index += 1
    }
    return options
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func rect(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = attribute(element, kAXPositionAttribute as String),
          let sizeValue = attribute(element, kAXSizeAttribute as String),
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
        return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
          AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else {
        return nil
    }
    return CGRect(origin: position, size: size)
}

func bundleIdentifier(forDockItem item: AXUIElement) -> String? {
    guard let value = attribute(item, kAXURLAttribute as String),
          let url = value as? NSURL else {
        return nil
    }
    return Bundle(url: url as URL)?.bundleIdentifier
}

func findDockItem(_ element: AXUIElement, bundleID: String, depth: Int = 0) -> AXUIElement? {
    guard depth <= 6 else { return nil }
    if bundleIdentifier(forDockItem: element) == bundleID { return element }
    for child in children(element) {
        if let match = findDockItem(child, bundleID: bundleID, depth: depth + 1) {
            return match
        }
    }
    return nil
}

func currentDockFrame(dockPID: pid_t, bundleID: String) -> CGRect? {
    guard let item = findDockItem(AXUIElementCreateApplication(dockPID), bundleID: bundleID) else {
        return nil
    }
    return rect(item)
}

func targetWindows(pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    return (attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? [])
        .filter { attribute($0, kAXRoleAttribute as String) as? String == kAXWindowRole as String }
}

func onScreenWindowExists(pid: pid_t) -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return windows.contains { window in
        guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
              (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
            return false
        }
        return frame.width > 40 && frame.height > 40
    }
}

func readWindowState(pid: pid_t) -> WindowState {
    let windows = targetWindows(pid: pid)
    let minimized = windows.reduce(into: 0) { count, window in
        if attribute(window, kAXMinimizedAttribute as String) as? Bool == true {
            count += 1
        }
    }
    return WindowState(total: windows.count,
                       minimized: minimized,
                       visibleOnScreen: onScreenWindowExists(pid: pid))
}

func waitForState(pid: pid_t, timeout: TimeInterval, matches: (WindowState) -> Bool) -> WindowState? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let state = readWindowState(pid: pid)
        if matches(state) { return state }
        Thread.sleep(forTimeInterval: 0.04)
    } while Date() < deadline
    return nil
}

func postMouseClick(at point: CGPoint) -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(mouseEventSource: source,
                             mouseType: .leftMouseDown,
                             mouseCursorPosition: point,
                             mouseButton: .left),
          let up = CGEvent(mouseEventSource: source,
                           mouseType: .leftMouseUp,
                           mouseCursorPosition: point,
                           mouseButton: .left) else {
        return false
    }

    // Keep each event a single click so the Dock does not interpret a rapid
    // sequence as a double-click command.
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.015)
    up.post(tap: .cghidEventTap)
    return true
}

func reportState(_ label: String, _ state: WindowState) {
    print("\(label): minimized=\(state.minimized)/\(state.total), visible=\(state.visibleOnScreen)")
}

func reportSnapshot(_ label: String, pid: pid_t, bundleID: String, dockPID: pid_t) {
    let state = readWindowState(pid: pid)
    let app = NSRunningApplication(processIdentifier: pid)
    let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    let frame = currentDockFrame(dockPID: dockPID, bundleID: bundleID)
    print("SNAPSHOT \(label): pid=\(pid), frontmost=\(isFrontmost), hidden=\(app?.isHidden ?? true), windows=\(state.minimized)/\(state.total) minimized, onScreen=\(state.visibleOnScreen), dockFrame=\(String(describing: frame))")
    for (index, window) in targetWindows(pid: pid).enumerated() {
        let minimized = attribute(window, kAXMinimizedAttribute as String) as? Bool ?? false
        print("  window[\(index + 1)] minimized=\(minimized), frame=\(String(describing: rect(window)))")
    }
}

func postDockClick(dockPID: pid_t, bundleID: String, label: String) -> Bool {
    guard let frame = currentDockFrame(dockPID: dockPID, bundleID: bundleID),
          frame.width > 4, frame.height > 4 else {
        print("EVENT \(label): Dock 图标位置不可用")
        return false
    }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    print("EVENT \(label): click at (\(Int(point.x)), \(Int(point.y))), frame=\(frame)")
    return postMouseClick(at: point)
}

func clickAndWaitForMinimized(pid: pid_t, dockPID: pid_t, bundleID: String) -> Bool {
    guard postDockClick(dockPID: dockPID, bundleID: bundleID, label: "single-collapse") else { return false }
    guard let state = waitForState(pid: pid, timeout: 5, matches: \.isFullyMinimized) else {
        reportState("单击收起超时", readWindowState(pid: pid))
        return false
    }
    reportState("单击收起", state)
    return true
}

func clickAndWaitForRestored(pid: pid_t, dockPID: pid_t, bundleID: String, label: String) -> Bool {
    guard postDockClick(dockPID: dockPID, bundleID: bundleID, label: label) else { return false }
    guard let state = waitForState(pid: pid, timeout: 5, matches: \.isRestored) else {
        reportState("恢复超时", readWindowState(pid: pid))
        return false
    }
    reportState("恢复", state)
    return true
}

func postClickBurst(count: Int, bundleID: String, dockPID: pid_t, intervalMilliseconds: Int) -> Bool {
    guard let frame = currentDockFrame(dockPID: dockPID, bundleID: bundleID),
          frame.width > 4, frame.height > 4 else { return false }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    let interval = Double(intervalMilliseconds) / 1000
    var lastClick = ProcessInfo.processInfo.systemUptime
    for clickIndex in 1...count {
        // AX 可能一直等到系统动画结束，连点之间只发送鼠标事件。
        let now = ProcessInfo.processInfo.systemUptime
        if clickIndex > 1 {
            let elapsed = now - lastClick
            print("EVENT burst-\(count)-click-\(clickIndex): gap=\(Int(elapsed * 1000)) ms")
            guard elapsed < interval + 0.10 else { return false }
        }
        lastClick = now
        guard postMouseClick(at: point) else { return false }
        if clickIndex < count {
            Thread.sleep(forTimeInterval: max(0, lastClick + interval - ProcessInfo.processInfo.systemUptime))
        }
    }
    return true
}

func transitionLogCount(containing marker: String) -> Int {
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DockClickMin.log")
    guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return 0 }
    return log.components(separatedBy: .newlines).filter { $0.contains(marker) }.count
}

func waitForNewTransitionLog(containing marker: String, previousCount: Int, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if transitionLogCount(containing: marker) > previousCount { return true }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    return false
}

func waitForStableState(pid: pid_t,
                        timeout: TimeInterval,
                        dwell: TimeInterval,
                        matches: (WindowState) -> Bool) -> WindowState? {
    let deadline = Date().addingTimeInterval(timeout)
    var stableSince: Date?
    var lastMatchingState: WindowState?
    repeat {
        let state = readWindowState(pid: pid)
        if matches(state) {
            if stableSince == nil { stableSince = Date() }
            lastMatchingState = state
            if Date().timeIntervalSince(stableSince!) >= dwell { return state }
        } else {
            stableSince = nil
            lastMatchingState = nil
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    if let stableSince = stableSince,
       Date().timeIntervalSince(stableSince) >= dwell {
        return lastMatchingState
    }
    return nil
}

let options = parseOptions()
guard AXIsProcessTrusted() else {
    fail("当前运行环境没有辅助功能权限。请在“隐私与安全性 › 辅助功能”允许运行 swift 的终端应用，然后重试。")
}
guard CGPreflightPostEventAccess() else {
    fail("当前运行环境没有发送系统鼠标事件的权限。请在“隐私与安全性 › 辅助功能”和“输入监控”允许运行脚本的终端应用，然后重试。")
}

let defaults = UserDefaults(suiteName: "com.geekaudio.DockClickMin")
guard let dockClickMin = NSRunningApplication.runningApplications(withBundleIdentifier: "com.geekaudio.DockClickMin").first else {
    fail("DockClickMin 未运行。先由用户正常启动已安装版本，再运行本脚本。")
}
guard defaults?.object(forKey: "enabled") as? Bool != false else {
    fail("DockClickMin 当前已停用。请先在菜单栏重新启用。")
}
guard (defaults?.string(forKey: "mode") ?? "minimize") == "minimize" else {
    fail("当前收起方式不是最小化，无法验证 Dock 中断恢复。")
}
if defaults?.stringArray(forKey: "protectedApps")?.contains(options.bundleID) == true {
    fail("目标应用在 DockClickMin 保护名单中：\(options.bundleID)")
}
if defaults?.stringArray(forKey: "nativeHideApps")?.contains(options.bundleID) == true {
    fail("目标应用使用原生隐藏策略：\(options.bundleID)")
}

guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleID).first else {
    fail("目标应用未运行：\(options.bundleID)。本脚本不会启动它。")
}
guard target.processIdentifier != dockClickMin.processIdentifier else {
    fail("不能把 DockClickMin 自身作为测试目标。")
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
    fail("请先手动把目标应用切到前台，再运行本脚本。")
}
guard !target.isHidden else {
    fail("目标应用当前处于隐藏状态，请先手动显示它。")
}

let pid = target.processIdentifier
let initialState = readWindowState(pid: pid)
guard initialState.total > 0, initialState.minimized == 0, initialState.visibleOnScreen else {
    reportState("初始状态", initialState)
    fail("目标应用需要至少一个位于屏幕上的未最小化窗口。Finder 是默认的安全测试目标。")
}

guard let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
      let dockFrame = currentDockFrame(dockPID: dockPID, bundleID: options.bundleID),
      dockFrame.width > 4, dockFrame.height > 4 else {
    fail("无法通过 Dock 辅助功能树定位目标图标。检查 Dock 的辅助功能可访问性和 Dock 自动隐藏状态。")
}
recoveryAction = {
    let state = readWindowState(pid: pid)
    if state.minimized > 0 {
        print("尝试恢复测试窗口")
        _ = postDockClick(dockPID: dockPID, bundleID: options.bundleID, label: "recovery")
        _ = waitForState(pid: pid, timeout: 5, matches: \.isRestored)
    }
}

let targetName = target.localizedName ?? options.bundleID
print("目标：\(targetName) (\(options.bundleID))，窗口 \(initialState.total) 个")
print("快速连点间隔：\(options.intervalMilliseconds) ms。所有事件发送到 Dock 图标中心。")
print("先验证单击收起和原生恢复，再验证快速双击恢复与快速三击收起。")
reportSnapshot("initial", pid: pid, bundleID: options.bundleID, dockPID: dockPID)

guard clickAndWaitForMinimized(pid: pid, dockPID: dockPID, bundleID: options.bundleID) else {
    fail("基线单击没有完成最小化。确认 DockClickMin 已获辅助功能与输入监控权限，并查看 ~/Library/Logs/DockClickMin.log。")
}
guard waitForStableState(pid: pid, timeout: 5, dwell: 0.7, matches: \.isFullyMinimized) != nil else {
    fail("基线最小化状态没有稳定。")
}
Thread.sleep(forTimeInterval: 0.8)
guard clickAndWaitForRestored(pid: pid,
                              dockPID: dockPID,
                              bundleID: options.bundleID,
                              label: "single-native-restore") else {
    fail("基线原生 Dock 恢复失败。")
}
guard waitForStableState(pid: pid, timeout: 5, dwell: 0.7, matches: \.isRestored) != nil else {
    fail("基线原生恢复状态没有稳定。")
}

Thread.sleep(forTimeInterval: 0.8)
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    fail("基线恢复后目标没有保持在前台，请手动恢复目标窗口后重试。")
}

reportSnapshot("before-double-click", pid: pid, bundleID: options.bundleID, dockPID: dockPID)
let doubleClickMarker = "连点 \(targetName) ×2：恢复"
let priorDoubleClickLogs = transitionLogCount(containing: doubleClickMarker)
guard postClickBurst(count: 2,
                     bundleID: options.bundleID,
                     dockPID: dockPID,
                     intervalMilliseconds: options.intervalMilliseconds) else {
    fail("快速双击发送失败。")
}
guard waitForNewTransitionLog(containing: doubleClickMarker,
                              previousCount: priorDoubleClickLogs,
                              timeout: 3) else {
    fail("DockClickMin 日志没有记录到目标应用的 ×2 恢复意图，无法确认第二击进入了中断处理路径。")
}

Thread.sleep(forTimeInterval: 0.8)
guard let interruptedState = waitForStableState(pid: pid, timeout: 6, dwell: 0.7, matches: \.isRestored) else {
    reportState("快速双击最终状态", readWindowState(pid: pid))
    fail("收起期间的第二击没有让目标窗口恢复。检查 DockClickMin 日志中的连续点击和恢复记录。")
}
reportState("快速双击最终状态", interruptedState)
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    fail("快速双击后窗口可见，但目标应用没有回到前台。")
}

Thread.sleep(forTimeInterval: 0.8)
reportSnapshot("before-triple-click", pid: pid, bundleID: options.bundleID, dockPID: dockPID)
let tripleClickMarker = "连点 \(targetName) ×3：收起"
let priorTripleClickLogs = transitionLogCount(containing: tripleClickMarker)
guard postClickBurst(count: 3,
                     bundleID: options.bundleID,
                     dockPID: dockPID,
                     intervalMilliseconds: options.intervalMilliseconds) else {
    fail("快速三击发送失败。")
}
guard waitForNewTransitionLog(containing: tripleClickMarker,
                              previousCount: priorTripleClickLogs,
                              timeout: 3) else {
    fail("DockClickMin 日志没有记录到目标应用的 ×3 收起意图。")
}
Thread.sleep(forTimeInterval: 0.8)
guard let tripleState = waitForStableState(pid: pid, timeout: 6, dwell: 0.7, matches: \.isFullyMinimized) else {
    reportState("快速三击最终状态", readWindowState(pid: pid))
    fail("快速三击后窗口没有稳定保持在最小化状态。")
}
reportState("快速三击最终状态", tripleState)
Thread.sleep(forTimeInterval: 0.8)

reportSnapshot("before-restore-interruption", pid: pid, bundleID: options.bundleID, dockPID: dockPID)
let restoreInterruptMarker = "连点 \(targetName) ×2：收起"
let priorRestoreInterruptLogs = transitionLogCount(containing: restoreInterruptMarker)
guard postClickBurst(count: 2,
                     bundleID: options.bundleID,
                     dockPID: dockPID,
                     intervalMilliseconds: options.intervalMilliseconds) else {
    fail("恢复过程中的快速双击发送失败。")
}
guard waitForNewTransitionLog(containing: restoreInterruptMarker,
                              previousCount: priorRestoreInterruptLogs,
                              timeout: 3) else {
    fail("DockClickMin 日志没有记录到恢复过程中的 ×2 收起意图。")
}
Thread.sleep(forTimeInterval: 0.8)
guard let restoreInterruptedState = waitForStableState(pid: pid,
                                                       timeout: 6,
                                                       dwell: 0.7,
                                                       matches: \.isFullyMinimized) else {
    reportState("恢复中快速双击最终状态", readWindowState(pid: pid))
    fail("恢复过程中的第二击没有稳定地重新收起窗口。")
}
reportState("恢复中快速双击最终状态", restoreInterruptedState)

Thread.sleep(forTimeInterval: 0.8)
guard clickAndWaitForRestored(pid: pid,
                              dockPID: dockPID,
                              bundleID: options.bundleID,
                              label: "final-native-restore") else {
    fail("最后一次原生 Dock 恢复失败。")
}
guard let finalState = waitForStableState(pid: pid, timeout: 6, dwell: 0.7, matches: \.isRestored) else {
    reportState("最终状态", readWindowState(pid: pid))
    fail("最后一次原生恢复后窗口没有稳定保持可见。")
}
reportState("最终状态", finalState)
Thread.sleep(forTimeInterval: 0.8)
reportSnapshot("final", pid: pid, bundleID: options.bundleID, dockPID: dockPID)
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    fail("快速三击最终恢复后，目标应用没有回到前台。")
}

recoveryAction = nil
print("PASS DockClickMin 真实 Dock 点击双击/三击/恢复中断测试")
print("目标窗口已保持可见。辅助功能和输入监控授权需分别由 DockClickMin 与运行本脚本的终端获得。")
