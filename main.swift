//
//  main.swift — DockClickMin
//  原生实现「点 Dock 图标 = 收起前台应用」（Windows 任务栏语义）
//
//  原理（纯系统 API，无第三方依赖）：
//   1. AXUIElement 读 Dock 进程的辅助功能树 → 每个应用图标的实时矩形 + bundle id
//   2. CGEventTap（listen-only，只监听不拦截，绝不改写你的输入）看左键按下/抬起
//   3. 按下时记住「当时的前台 app」；抬起时若落点仍在同一个图标内、且该 app 就是
//      按下时的前台 app ⇒ 这是「再次点击已在前台的图标」⇒ 收起它
//
//  为什么不用 applicationShouldHandleReopen：app 已在前台时 Dock 根本不发 rapp 事件，
//  那个回调不会被调用，所以纯 app 内方案做不到 Windows 任务栏效果。
//

import Cocoa
import ApplicationServices

// MARK: - 日志

private let kLogURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Logs/DockClickMin.log")
private let kLogQueue = DispatchQueue(label: "com.geekaudio.dockclickmin.log")

func dlog(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss.SSS"
    let line = "[\(f.string(from: Date()))] \(s)\n"
    kLogQueue.async {
        let data = Data(line.utf8)
        if let h = try? FileHandle(forWritingTo: kLogURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: kLogURL)
        }
    }
}

// MARK: - 设置

enum CollapseMode: String {
    case hide       // 整个 app 收起（最接近 Windows 任务栏）
    case minimize   // 只把窗口最小化进 Dock 图标
}

enum Prefs {
    static var mode: CollapseMode {
        get { CollapseMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .minimize }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mode") }
    }
    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "enabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "enabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }
}

// MARK: - 辅助功能权限

func axTrusted(prompt: Bool = false) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

// MARK: - Dock 图标枚举（AX）

struct DockTile {
    let pid: pid_t
    let name: String
    let rect: CGRect
}

enum DockAX {
    static func dockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    /// Dock 上所有「正在运行的应用图标」的实时矩形
    static func tiles() -> [DockTile] {
        guard let pid = dockPID() else { return [] }
        var out: [DockTile] = []
        collect(AXUIElementCreateApplication(pid), depth: 0, into: &out)
        return out
    }

    /// (窗口总数, 已最小化数)
    static func windowStats(pid: pid_t) -> (total: Int, minimized: Int) {
        let el = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return (0, 0) }
        var mini = 0
        for w in wins {
            var cur: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &cur) == .success,
               let b = cur as? Bool, b { mini += 1 }
        }
        return (wins.count, mini)
    }

    /// 第一个窗口的当前尺寸（自测时用来观察最小化动画有没有中间帧）
    static func firstWindowSize(pid: pid_t) -> CGSize? {
        let el = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement], let w = wins.first else { return nil }
        var sRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sRef) == .success,
              let s = sizeValue(sRef) else { return nil }
        return s
    }

    /// 还原所有窗口（自测后恢复桌面）
    static func restoreAll(pid: pid_t) {
        let el = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return }
        for w in wins {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let el = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return [] }
        return wins
    }

    static func isMinimized(_ w: AXUIElement) -> Bool {
        var cur: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &cur) == .success,
              let b = cur as? Bool else { return false }
        return b
    }

    static func minimizeButton(_ w: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXMinimizeButtonAttribute as CFString, &ref) == .success,
              let r = ref, CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(r, to: AXUIElement.self)
    }

    // 供 dump / 诊断使用
    static func text(_ el: AXUIElement, _ name: String) -> String {
        str(el, name) ?? ""
    }
    static func rect(_ el: AXUIElement) -> CGRect? { frame(el) }

    private static func collect(_ el: AXUIElement, depth: Int, into out: inout [DockTile]) {
        guard depth <= 5, let kids = children(el) else { return }
        for k in kids {
            if str(k, kAXSubroleAttribute as String) == "AXApplicationDockItem" {
                if let t = tile(k) { out.append(t) }
            } else {
                collect(k, depth: depth + 1, into: &out)
            }
        }
    }

    private static func tile(_ el: AXUIElement) -> DockTile? {
        guard let rect = frame(el), rect.width > 4, rect.height > 4 else { return nil }
        guard let app = runningApp(el) else { return nil }
        return DockTile(pid: app.processIdentifier,
                        name: app.localizedName ?? "?",
                        rect: rect)
    }

    private static func runningApp(_ el: AXUIElement) -> NSRunningApplication? {
        if let bid = bundleID(el),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            return app
        }
        // 兜底：用图标标题匹配本地化名称
        if let t = str(el, kAXTitleAttribute as String) {
            let all = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            if let a = all.first(where: { $0.localizedName == t }) { return a }
        }
        return nil
    }

    private static func bundleID(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &v) == .success,
              let v = v else { return nil }
        if let nsurl = v as? NSURL {
            return Bundle(url: nsurl as URL)?.bundleIdentifier
        }
        return nil
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement]? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return nil }
        return v as? [AXUIElement]
    }

    private static func str(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        var pRef: CFTypeRef?
        var sRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sRef) == .success,
              let p = pointValue(pRef), let s = sizeValue(sRef) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func pointValue(_ v: CFTypeRef?) -> CGPoint? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgPoint, &p) ? p : nil
    }

    private static func sizeValue(_ v: CFTypeRef?) -> CGSize? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgSize, &s) ? s : nil
    }
}

// MARK: - 图标矩形缓存（每秒刷新，给点击做廉价第一道过滤）

final class TileCache {
    static let shared = TileCache()

    private let lock = NSLock()
    private var _tiles: [DockTile] = []
    private var _band: CGRect = .null
    private var timer: DispatchSourceTimer?

    var tiles: [DockTile] { lock.lock(); defer { lock.unlock() }; return _tiles }
    /// 所有图标矩形的并集，四周外扩 60pt（吸收放大动画带来的抖动）
    var band: CGRect { lock.lock(); defer { lock.unlock() }; return _band }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.geekaudio.dockclickmin.tilecache",
                                                                   qos: .utility))
        t.schedule(deadline: .now() + 0.1, repeating: 1.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock(); _tiles = []; _band = .null; lock.unlock()
    }

    func refresh() {
        let list = DockAX.tiles()
        var u = CGRect.null
        for t in list { u = u.union(t.rect) }
        lock.lock()
        _tiles = list
        _band = u.isNull ? .null : u.insetBy(dx: -60, dy: -60)
        lock.unlock()
    }
}

// MARK: - Dock 窗口范围（诊断用；注意：中文系统 owner 名是「程序坞」不是 Dock）

func dockWindowFrames() -> [CGRect] {
    guard let dockPID = DockAX.dockPID() else { return [] }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [CGRect] = []
    for w in list {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid == dockPID else { continue }
        guard let b = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
        out.append(rect)
    }
    return out
}

// MARK: - 事件监听

final class ClickMonitor {
    static let shared = ClickMonitor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pending: (tile: DockTile, down: CGPoint)?
    private let work = DispatchQueue(label: "com.geekaudio.dockclickmin.work")
    private(set) var lastError: String?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        lastError = nil
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask),
                                        callback: { _, type, event, _ in
                                            ClickMonitor.shared.handle(type: type, event: event)
                                            return Unmanaged.passUnretained(event)
                                        },
                                        userInfo: nil) else {
            lastError = "tapCreate 失败（缺「辅助功能」或「输入监控」权限）"
            dlog(lastError!)
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = src
        TileCache.shared.start()
        dlog("事件监听已启动")
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        TileCache.shared.stop()
        dlog("事件监听已停止")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            dlog("tap 被系统临时禁用，已重新启用")
            return
        }
        guard Prefs.enabled else { return }

        // 带修饰键时完全放行：保留 ⌥-click「隐藏其他」、⌘-click 等原生行为
        let mods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        if !event.flags.intersection(mods).isEmpty {
            work.async { self.pending = nil }
            return
        }

        let loc = event.location
        switch type {
        case .leftMouseDown:
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            work.async { self.onDown(loc, front) }
        case .leftMouseUp:
            work.async { self.onUp(loc) }
        default:
            break
        }
    }

    // 以下三个方法都在串行队列 work 上执行，pending 无需加锁

    private func onDown(_ p: CGPoint, _ front: pid_t) {
        pending = nil
        let band = TileCache.shared.band
        guard !band.isNull, band.contains(p) else { return }
        guard let tile = DockAX.tiles().first(where: { $0.rect.contains(p) }) else { return }
        guard tile.pid == front else { return }          // 点的是别的 app ⇒ 交给系统
        // 无窗口 ⇒ 保留原生「打开新窗口」；窗口已全部最小化 ⇒ 保留原生「点图标恢复」
        let stats = DockAX.windowStats(pid: tile.pid)
        guard stats.total > 0, stats.minimized < stats.total else { return }
        pending = (tile, p)
    }

    private func onUp(_ p: CGPoint) {
        guard let (tile, down) = pending else { return }
        pending = nil
        guard hypot(p.x - down.x, p.y - down.y) < 8, tile.rect.contains(p) else { return }
        act(tile)
    }

    private func act(_ tile: DockTile) {
        guard let app = NSRunningApplication(processIdentifier: tile.pid) else { return }
        switch Prefs.mode {
        case .hide:
            let ok = app.hide()
            dlog("收起 \(tile.name)（hide ok=\(ok)）")
        case .minimize:
            let r = minimizeAll(pid: tile.pid)
            dlog("收起 \(tile.name)：\(r)")
        }
        TileCache.shared.refresh()
    }

    /// 自测用：把「按下→抬起」整条判定链跑一遍（不依赖真实鼠标事件）
    func testPipeline(at p: CGPoint, front: pid_t) {
        work.sync {
            self.onDown(p, front)
            self.onUp(p)
        }
    }

    /// 三级回退，每级都验证结果：
    ///   ① 按窗口自己的黄色按钮（与手点等价，genie 动画）
    ///   ② 向该进程发 ⌘M（走 app 自己的「最小化」菜单命令，也有动画）
    ///   ③ 直接置 AXMinimized（无动画，最后兜底）
    /// 有的 app（QQ / ChatGPT）对 ① 返回 success 但窗口不动，必须靠 ②③ 兜住。
    @discardableResult
    private func minimizeAll(pid: pid_t) -> String {
        let (total, before) = DockAX.windowStats(pid: pid)
        guard total > 0 else { return "无窗口" }
        var report: [String] = []

        // ① 按黄色按钮
        var pressed = 0
        for w in DockAX.windows(pid: pid) {
            guard !DockAX.isMinimized(w) else { continue }
            if let b = DockAX.minimizeButton(w), AXUIElementPerformAction(b, kAXPressAction as CFString) == .success {
                pressed += 1
            }
        }
        usleep(180_000)
        var (t, m) = DockAX.windowStats(pid: pid)
        report.append("按钮 \(pressed) 成功→\(m)/\(t)")
        if m >= t { return report.joined(separator: " / ") }

        // ② ⌘M 给还没动的窗口
        var sent = 0
        for _ in 0..<max(0, t - m) {
            sendCmdM(pid: pid)
            sent += 1
            usleep(120_000)
        }
        (t, m) = DockAX.windowStats(pid: pid)
        report.append("⌘M \(sent) 次→\(m)/\(t)")
        if m >= t { return report.joined(separator: " / ") }

        // ③ 直接置属性
        var forced = 0
        for w in DockAX.windows(pid: pid) where !DockAX.isMinimized(w) {
            if AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                forced += 1
            }
        }
        (t, m) = DockAX.windowStats(pid: pid)
        report.append("置属性 \(forced)→\(m)/\(t)")
        report.append("起始 \(before)/\(total)")
        return report.joined(separator: " / ")
    }

    /// 向指定进程发 ⌘M（app 自己的「窗口 › 最小化」菜单命令）
    private func sendCmdM(pid: pid_t) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 0x2E, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x2E, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }
}

// MARK: - 菜单栏

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockClickMin")
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuild()

        let trusted = axTrusted(prompt: true)
        dlog("启动，AX 授权=\(trusted)")
        if trusted { _ = ClickMonitor.shared.start() }

        // 启动后自检：把枚举到的 Dock 图标写进日志，便于排错
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let logs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs")
            let sentinel = logs.appendingPathComponent("DockClickMin.selftest")
            let dumpFlag = logs.appendingPathComponent("DockClickMin.dump")
            if FileManager.default.fileExists(atPath: dumpFlag.path) {
                try? FileManager.default.removeItem(at: dumpFlag)
                runDump()
                exit(0)
            }
            if CommandLine.arguments.contains("--selftest") || FileManager.default.fileExists(atPath: sentinel.path) {
                try? FileManager.default.removeItem(at: sentinel)
                runSelfTest()
                return
            }
            TileCache.shared.refresh()
            let tiles = TileCache.shared.tiles
            dlog("自检：识别图标 \(tiles.count) 个，band=\(TileCache.shared.band)")
            for t in tiles.prefix(8) { dlog("   \(t.name) pid=\(t.pid) \(t.rect)") }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        ClickMonitor.shared.stop()
    }

    func menuWillOpen(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let trusted = axTrusted()
        if trusted && Prefs.enabled && !ClickMonitor.shared.isRunning {
            _ = ClickMonitor.shared.start()
        }
        let running = ClickMonitor.shared.isRunning

        if !trusted {
            let it = NSMenuItem(title: "⚠︎ 未授权：点这里开启「辅助功能」",
                                action: #selector(openAXSettings), keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        } else if !running {
            let it = NSMenuItem(title: "⚠︎ 监听未启动：点这里检查权限",
                                action: #selector(openAXSettings), keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }

        let head = NSMenuItem(title: "点 Dock 图标 → 收起前台应用", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        let enable = NSMenuItem(title: "启用", action: #selector(toggleEnabled), keyEquivalent: "")
        enable.target = self
        enable.state = Prefs.enabled ? .on : .off
        menu.addItem(enable)

        let minimizeItem = NSMenuItem(title: "收起方式：最小化窗口（原生动画）", action: #selector(useMinimize), keyEquivalent: "")
        minimizeItem.target = self
        minimizeItem.state = Prefs.mode == .minimize ? .on : .off
        menu.addItem(minimizeItem)

        let hideItem = NSMenuItem(title: "收起方式：隐藏整个应用（瞬时，无动画）", action: #selector(useHide), keyEquivalent: "")
        hideItem.target = self
        hideItem.state = Prefs.mode == .hide ? .on : .off
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let detail = "\(TileCache.shared.tiles.count) 个图标"
        let state = NSMenuItem(title: "状态：" + (trusted ? (running ? "监听中 · " + detail : "已授权，未监听")
                                                        : "缺权限"),
                              action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)

        let openLog = NSMenuItem(title: "打开日志", action: #selector(showLog), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        Prefs.enabled.toggle()
        if Prefs.enabled && axTrusted() { _ = ClickMonitor.shared.start() } else { ClickMonitor.shared.stop() }
        rebuild()
    }

    @objc private func useHide() {
        Prefs.mode = .hide
        rebuild()
    }

    @objc private func useMinimize() {
        Prefs.mode = .minimize
        rebuild()
    }

    @objc private func openAXSettings() {
        _ = axTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showLog() {
        if !FileManager.default.fileExists(atPath: kLogURL.path) {
            FileManager.default.createFile(atPath: kLogURL.path, contents: nil)
        }
        NSWorkspace.shared.open(kLogURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 窗口结构 dump（排查「某些 app 不认最小化」用）

func runDump() {
    dlog("=== dump 开始 ===")
    for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
        let pid = app.processIdentifier
        let wins = DockAX.windows(pid: pid)
        guard !wins.isEmpty else { continue }
        let (t, m) = DockAX.windowStats(pid: pid)
        dlog("\(app.localizedName ?? "?") pid=\(pid) 窗口=\(t) 已最小化=\(m) 前台=\(app.isActive)")
        for (i, w) in wins.enumerated() {
            let title = DockAX.text(w, kAXTitleAttribute as String)
            let sub = DockAX.text(w, kAXSubroleAttribute as String)
            let role = DockAX.text(w, kAXRoleAttribute as String)
            let f = DockAX.rect(w).map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
            let btn = DockAX.minimizeButton(w) != nil ? "有" : "无"
            dlog("   [\(i)] 「\(title)」 role=\(role) sub=\(sub) min=\(DockAX.isMinimized(w)) frame=\(f) 按钮=\(btn)")
        }
    }
    dlog("=== dump 结束 ===")
}

// MARK: - 自测（--selftest，必须通过 LaunchServices 启动，否则拿不到 TCC 授权）

func runSelfTest() {
    dlog("=== selftest 开始 ===")
    dlog("AX 授权=\(axTrusted())")
    let tiles = DockAX.tiles()
    dlog("识别图标 \(tiles.count) 个")
    for t in tiles { dlog("   \(t.name) pid=\(t.pid) \(t.rect)") }

    guard let front = NSWorkspace.shared.frontmostApplication else {
        dlog("结论：拿不到前台 app"); exit(0)
    }
    dlog("前台 \(front.localizedName ?? "?") pid=\(front.processIdentifier)")

    guard let tile = tiles.first(where: { $0.pid == front.processIdentifier }) else {
        dlog("结论：前台 app 没有对应的 Dock 图标，无法自测"); exit(0)
    }
    let c = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
    dlog("模拟点击「\(tile.name)」图标中心 \(c)，模式=\(Prefs.mode.rawValue)")

    // 采样窗口尺寸：如果最小化走的是动画，尺寸序列会出现中间帧
    var seq: [String] = []
    let sampler = DispatchSource.makeTimerSource(queue: .main)
    sampler.schedule(deadline: .now(), repeating: .milliseconds(12))
    sampler.setEventHandler {
        if let s = DockAX.firstWindowSize(pid: front.processIdentifier) {
            let str = "\(Int(s.width))x\(Int(s.height))"
            if seq.last != str { seq.append(str) }
        }
    }
    sampler.resume()

    ClickMonitor.shared.testPipeline(at: c, front: front.processIdentifier)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        sampler.cancel()
        let app = NSRunningApplication(processIdentifier: front.processIdentifier)
        let hidden = app?.isHidden ?? false
        let stats = DockAX.windowStats(pid: front.processIdentifier)
        dlog("窗口尺寸序列（\(seq.count) 段）：\(seq.prefix(12).joined(separator: " → "))")
        dlog("结果：isHidden=\(hidden) 窗口 \(stats.minimized)/\(stats.total) 已最小化")
        let ok = Prefs.mode == .hide ? hidden : (stats.total > 0 && stats.minimized == stats.total)
        dlog(ok ? "结论：PASS —— 点图标成功收起了「\(tile.name)」"
                : "结论：FAIL —— 没有收起")
        if hidden { app?.unhide(); app?.activate(options: []) }
        if Prefs.mode == .minimize {
            DockAX.restoreAll(pid: front.processIdentifier)
            dlog("已还原窗口（自测不改变你的桌面状态）")
        }
        dlog("=== selftest 结束 ===")
        exit(0)
    }
}

// MARK: - 诊断模式

func runDiagnose() {
    print("AX 授权:", axTrusted())
    print("Dock pid:", DockAX.dockPID().map(String.init) ?? "未找到")
    let frames = dockWindowFrames()
    print("Dock 窗口数:", frames.count)
    for r in frames { print("    ", r) }
    let tiles = DockAX.tiles()
    print("可识别图标数:", tiles.count)
    for t in tiles { print("    -", t.name, "pid=\(t.pid)", t.rect) }
    print("缓存 band:", TileCache.shared.band)
    if let f = NSWorkspace.shared.frontmostApplication {
        print("当前前台:", f.localizedName ?? "?", "pid=\(f.processIdentifier)")
    }
}

// MARK: - 入口

if CommandLine.arguments.contains("--diagnose") {
    runDiagnose()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
