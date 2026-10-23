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
    /// 开机自启，默认开（key 不存在时按 true 处理）
    static var autoStart: Bool {
        get {
            if UserDefaults.standard.object(forKey: "autoStart") == nil { return true }
            return UserDefaults.standard.bool(forKey: "autoStart")
        }
        set { UserDefaults.standard.set(newValue, forKey: "autoStart") }
    }
    /// 唤出应用时把窗口提到最前，默认开
    static var raiseOnSummon: Bool {
        get {
            if UserDefaults.standard.object(forKey: "raiseOnSummon") == nil { return true }
            return UserDefaults.standard.bool(forKey: "raiseOnSummon")
        }
        set { UserDefaults.standard.set(newValue, forKey: "raiseOnSummon") }
    }
    /// 保护名单：这些应用点图标时完全不收起。
    /// 默认含访达（系统外壳）和 QQ —— **QQ 只要被最小化再恢复，就会把自己窗口设成浮动层级**
    /// （实测：手动点黄色按钮最小化再恢复也照样置顶，是 QQ 自身行为，与工具无关），
    /// 所以默认不碰它，避免替用户触发这个副作用。
    /// 可自行增删，不必重新编译：
    ///   defaults write com.geekaudio.DockClickMin protectedApps -array com.apple.finder
    static var protectedApps: Set<String> {
        let def = ["com.apple.finder", "com.tencent.qq"]
        let arr = UserDefaults.standard.stringArray(forKey: "protectedApps") ?? def
        return Set(arr)
    }
    /// 温和名单：这些应用只用 ⌘M 收起，不按 AX 按钮、不置 AXMinimized。
    /// 原因：实测 Electron 系应用（QQ）被外部置 AXMinimized 后会把自己窗口重新设成浮动层级，
    /// 表现为「一直被置顶，别的程序盖不住」。默认含 QQ，可自行增删。
    static var gentleApps: Set<String> {
        let def = ["com.tencent.qq"]
        let arr = UserDefaults.standard.stringArray(forKey: "gentleApps") ?? def
        return Set(arr)
    }
    /// 这些应用「从最小化恢复」时走 AX 恢复，不让 Dock 参与。
    /// 用来验证 QQ 的置顶是不是 Dock 恢复路径触发的。默认含 QQ，可自行增删。
    static var axRestoreApps: Set<String> {
        let def = ["com.tencent.qq"]
        let arr = UserDefaults.standard.stringArray(forKey: "axRestoreApps") ?? def
        return Set(arr)
    }
}

// MARK: - 开机自启（LaunchAgent，登录时 launchd 自动加载，无需 root）

enum AutoStart {
    static let label = "com.geekaudio.DockClickMin"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var installed: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// 写入/更新 plist（每次启动都对齐当前路径，app 被移动也能自愈）
    @discardableResult
    static func ensure() -> Bool {
        guard let exe = Bundle.main.executableURL?.path else { return false }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(exe)</string></array>
            <key>RunAtLoad</key><true/>
            <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try xml.write(to: plistURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            dlog("开机自启写入失败：\(error.localizedDescription)")
            return false
        }
    }

    static func disable() {
        let uid = getuid()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(uid)/\(label)"]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// 启动时对齐：勾选 ⇒ 每次启动都按当前可执行路径重写 plist（app 移动/换目录后自愈）；
    /// 取消 ⇒ 删掉
    static func sync() {
        if Prefs.autoStart {
            ensure()
        } else if installed {
            disable()
        }
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
    let bundleID: String?
    let rect: CGRect
}

/// 启动台 / Launchpad 这类「全屏启动器」不是普通 app：点图标应当**关闭**它，不是最小化
let kLauncherIDs: Set<String> = ["com.apple.apps.launcher",     // macOS 26 Tahoe 的 Apps.app
                                 "com.apple.launchpad.launcher"] // 老 Launchpad
let kLauncherNames: Set<String> = ["启动台", "Launchpad", "App", "Apps"]

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
        let wins = windows(pid: pid)          // 已过滤掉 AXScrollArea 之类的非窗口元素
        guard !wins.isEmpty else { return (0, 0) }
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
        for w in windows(pid: pid) {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    /// 真正的窗口：`kAXWindowsAttribute` 会混进非窗口元素（访达把桌面滚动区
    /// `AXScrollArea` 也塞进来，它没有最小化按钮、永远收不起来，会让统计卡在 1/2）
    static func windows(pid: pid_t) -> [AXUIElement] {
        let el = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return [] }
        return wins.filter { (str($0, kAXRoleAttribute as String) ?? "") == (kAXWindowRole as String) }
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

    /// 顶层菜单标题（用来判断 app 有没有「隐藏 / 最小化 / 关闭」这些菜单项）
    static func menuBarTitles(pid: pid_t) -> [String]? {
        let appEl = AXUIElementCreateApplication(pid)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let b = barRef, CFGetTypeID(b) == AXUIElementGetTypeID() else { return nil }
        let bar = unsafeBitCast(b, to: AXUIElement.self)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &v) == .success,
              let items = v as? [AXUIElement] else { return nil }
        return items.compactMap { str($0, kAXTitleAttribute as String) }.filter { !$0.isEmpty }
    }

    private static func collect(_ el: AXUIElement, depth: Int, into out: inout [DockTile]) {
        guard depth <= 5, let kids = children(el) else { return }
        for k in kids {
            let sub = str(k, kAXSubroleAttribute as String) ?? ""
            // 放宽：AXApplicationDockItem / AXFolderDockItem / AXURLDockItem … 只要是个 Dock 图标都收
            if sub.hasSuffix("DockItem") {
                if let t = tile(k) { out.append(t) }
            } else {
                collect(k, depth: depth + 1, into: &out)
            }
        }
    }

    private static func tile(_ el: AXUIElement) -> DockTile? {
        guard let rect = frame(el), rect.width > 4, rect.height > 4 else { return nil }
        let title = str(el, kAXTitleAttribute as String) ?? "?"
        var bid = bundleID(el)
        // 启动台这类图标可能拿不到 AXURL，用标题兜底映射
        if bid == nil, kLauncherNames.contains(title) { bid = "com.apple.apps.launcher" }

        if let app = runningApp(el, bundleID: bid) {
            return DockTile(pid: app.processIdentifier,
                            name: app.localizedName ?? title,
                            bundleID: bid ?? app.bundleIdentifier,
                            rect: rect)
        }
        // 未运行但有 bundle id（启动台这类按需启动的 LSUIElement）：保留矩形，点击时再实时查进程
        if let bid = bid {
            return DockTile(pid: -1, name: title, bundleID: bid, rect: rect)
        }
        return nil
    }

    private static func runningApp(_ el: AXUIElement, bundleID bid: String?) -> NSRunningApplication? {
        if let bid = bid,
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

// MARK: - Dock 窗口（注意：中文系统 owner 名是「程序坞」不是 Dock，只能按 pid 认）

struct DockWindowInfo {
    let layer: Int
    let rect: CGRect
}

func dockWindows() -> [DockWindowInfo] {
    guard let dockPID = DockAX.dockPID() else { return [] }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [DockWindowInfo] = []
    for w in list {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid == dockPID else { continue }
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let rect = (w[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        out.append(DockWindowInfo(layer: layer, rect: rect))
    }
    return out
}

func dockWindowFrames() -> [CGRect] { dockWindows().map { $0.rect } }

/// macOS 26 的启动台（Apps.app）界面实际由**聚焦 / Spotlight** 托管：
/// 实测打开时 `owner=聚焦 pid=657 layer=23 rect=747,303 844x577`，
/// 而旧版本（Tahoe 早期）是程序坞自己画的两个全屏窗口（layer 27/29）。
/// 两条路径都认，否则层级一变就失效。
let kLauncherHostIDs: Set<String> = ["com.apple.Spotlight"]

/// 启动台开着时，程序坞会多出全屏覆盖层窗口，layer 从 20 升到 27/29。
/// 关闭时只有 layer=20 那一个。实测依据见 README。
func launcherOverlayOpen() -> Bool {
    if dockWindows().contains(where: { $0.layer >= 26 }) { return true }
    return launcherHostHasWindow()
}

/// 启动台的宿主进程（聚焦）当前有没有可见窗口
func launcherHostHasWindow() -> Bool {
    let pids = Set(kLauncherHostIDs.flatMap {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).map { $0.processIdentifier }
    })
    guard !pids.isEmpty else { return false }
    let arr = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in arr {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else { continue }
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
        if alpha <= 0.01 { continue }
        guard let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b as CFDictionary),
              r.width >= 300, r.height >= 200 else { continue }
        return true
    }
    return false
}

/// 启动台宿主进程的 pid（关闭时要发 Esc 给它）
func launcherHostPID() -> pid_t? {
    for b in kLauncherHostIDs {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
            return app.processIdentifier
        }
    }
    return nil
}

/// 屏幕窗口栈里最上层的「普通窗口」（layer 0）属于谁。
/// 用途：窗口已经在最上面、但系统不认为它是活跃应用时，点它的图标应当直接收起，而不是先"切换"。
func topmostNormalWindowPID() -> pid_t? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    let me = getpid()
    let dockPID = DockAX.dockPID()
    for w in list {
        guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
        if pid == me || pid == dockPID { continue }
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
        if alpha <= 0.01 { continue }
        guard let b = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
              rect.width > 40, rect.height > 40 else { continue }
        return pid
    }
    return nil
}

// MARK: - 取消 QQ 置顶


// MARK: - 事件监听

final class ClickMonitor {
    static let shared = ClickMonitor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pending: (tile: DockTile, down: CGPoint)?
    private var raisePending: pid_t?
    /// 刚刚对它做过收起动作（最小化/隐藏）的时间戳：此期间不允许「提到最前」再把它拉回来
    private var suppressRaiseUntil: Date = .distantPast
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
                                        options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask),
                                        callback: { _, type, event, _ in
                                            if let out = ClickMonitor.shared.handle(type: type, event: event) {
                                                return Unmanaged.passUnretained(out)
                                            }
                                            return nil          // 吞掉这次事件
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

    private var swallowUp = false
    /// 非 nil 表示「这次抬起要改走 AX 恢复」——用来绕开 Dock 的恢复路径
    private var axRestorePID: pid_t?

    /// 返回 nil = 吞掉这次事件；返回 event = 原样放行
    fileprivate func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            dlog("tap 被系统临时禁用，已重新启用")
            return event
        }
        guard Prefs.enabled else { return event }

        // 带修饰键时完全放行：保留 ⌥-click「隐藏其他」、⌘-click 等原生行为
        let mods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        if !event.flags.intersection(mods).isEmpty {
            work.async { self.pending = nil }
            return event
        }

        let loc = event.location
        switch type {
        case .leftMouseDown:
            // 启动台快速路径：只用缓存矩形判断（几微秒），命中就吞掉这次点击，
            // 让程序坞完全不处理它，同时立刻发 Esc —— 这样没有「关掉又被点开」的竞争。
            if let t = TileCache.shared.tiles.first(where: { $0.rect.contains(loc) }),
               isLauncher(t), launcherOverlayOpen() {
                swallowUp = true
                closeLauncherFast()
                return nil
            }
            // 实验路径：名单内应用（默认 QQ）已全部最小化时，抬起改走 AX 恢复，
            // 不让 Dock 执行它自己的恢复 —— 用来看置顶是不是 Dock 恢复路径触发的
            if let t = TileCache.shared.tiles.first(where: { $0.rect.contains(loc) }),
               let bid = t.bundleID, Prefs.axRestoreApps.contains(bid), t.pid > 0 {
                let st = DockAX.windowStats(pid: t.pid)
                if st.total > 0, st.minimized >= st.total {
                    axRestorePID = t.pid
                    dlog("\(t.name) 已最小化 → 抬起时改用 AX 恢复（绕开 Dock）")
                }
            }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            work.async { self.onDown(loc, front) }
        case .leftMouseUp:
            if let pid = axRestorePID {
                axRestorePID = nil
                swallowUp = false
                work.async { self.axRestore(pid) }
                return nil                      // 吞掉，Dock 就不执行它的恢复
            }
            if swallowUp {
                swallowUp = false
                return nil
            }
            work.async { self.onUp(loc) }
        default:
            break
        }
        return event
    }

    /// 吞点击后的快速关闭：不用 Esc（实测会把聚焦搜索唤起来）。
    /// 用 Docklet 自己的开关通知 + 激活前台应用（启动台是非激活覆盖层，前台一变就收起）
    private func closeLauncherFast() {
        dismissLauncher()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            if launcherOverlayOpen() {
                self.work.async { self.closeLauncher() }
            } else {
                dlog("关闭启动台：吞点击 + 通知/激活 生效")
            }
        }
    }

    /// 关闭启动台。启动台是**非激活覆盖层**，前台一变就收起；但激活「已经在台前」的应用是空操作，
    /// 所以要先激活一个替身应用，再切回原来的。hide()/terminate() 对聚焦都无效（实测）。
    private func dismissLauncher() {
        guard let keep = NSWorkspace.shared.frontmostApplication, !keep.isTerminated else { return }
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != keep.processIdentifier
        }
        // 替身优先访达（最不容易抢戏），没有就随便挑一个
        guard let sub = others.first(where: { $0.bundleIdentifier == "com.apple.finder" }) ?? others.first else { return }
        sub.activate(options: [])
        usleep(180_000)
        keep.activate(options: [])
    }

    // 以下三个方法都在串行队列 work 上执行，pending 无需加锁

    private var downSeen = 0

    private func onDown(_ p: CGPoint, _ front: pid_t) {
        downSeen += 1
        pending = nil
        let band = TileCache.shared.band
        let inBand = !band.isNull && band.contains(p)
        let tiles = DockAX.tiles()
        let hit = tiles.first(where: { $0.rect.contains(p) })

        // 埋点：只记落在 Dock 区域/图标上的点击，平时很安静，排错时能定位到具体哪一步断了
        if inBand || hit != nil {
            let h = hit.map { "\($0.name)|\($0.bundleID ?? "-")|pid=\($0.pid)" } ?? "nil"
            dlog("DOWN#\(downSeen) \(Int(p.x)),\(Int(p.y)) inBand=\(inBand) tiles=\(tiles.count) hit=\(h) front=\(front) top=\(topmostNormalWindowPID().map(String.init) ?? "-") overlay=\(launcherOverlayOpen())")
        }

        guard inBand, let tile = hit else { return }

        // 启动台：点图标 = 关闭它（启动器没有「最小化」语义，也不该看窗口数）
        if isLauncher(tile) {
            // 必须用「按下时」的状态判断：抬起时原生可能已经把覆盖层打开了
            guard launcherOverlayOpen() else { return }   // 关着 ⇒ 让原生去打开
            // 注意：不在这里发 Esc。按下就发会被这次点击的处理压住，反而更慢，
            // 而且可能「先关后开」。统一放到 mouseUp 之后发。
            pending = (DockTile(pid: -1, name: tile.name, bundleID: tile.bundleID, rect: tile.rect), p)
            dlog("启动台开着 → 抬起后关闭")
            return
        }

        // 保护名单（默认含访达）：完全放行，交给系统原生行为
        if let bid = tile.bundleID, Prefs.protectedApps.contains(bid) {
            dlog("跳过 \(tile.name)（保护名单）")
            return
        }

        // 点的是别的应用 ⇒ 交给系统切换，但抬起后把它的窗口提到最前
        // 例外：它的窗口已经在窗口栈最上层（只是不是"活跃应用"）时，直接收起，一步到位
        let topPID = topmostNormalWindowPID()
        if tile.pid != front && tile.pid != topPID {
            if Prefs.raiseOnSummon { raisePending = tile.pid }
            return
        }

        // 无窗口 / 窗口已全部最小化 ⇒ 系统会自己「打开新窗口 / 恢复所有窗口」，之后也提一下
        let stats = DockAX.windowStats(pid: tile.pid)
        guard stats.total > 0, stats.minimized < stats.total else {
            if Prefs.raiseOnSummon { raisePending = tile.pid }
            return
        }
        pending = (tile, p)
    }

    private func isLauncher(_ t: DockTile) -> Bool {
        if let b = t.bundleID, kLauncherIDs.contains(b) { return true }
        return kLauncherNames.contains(t.name)
    }

    private func onUp(_ p: CGPoint) {
        if let pid = raisePending {
            raisePending = nil
            // 等 Dock 完成激活 / 恢复窗口，再把窗口提到最前（同一个串行队列，状态不打架）
            work.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                self?.raiseApp(pid: pid)
            }
        }
        guard let (tile, down) = pending else { return }
        pending = nil
        guard hypot(p.x - down.x, p.y - down.y) < 8, tile.rect.contains(p) else { return }
        act(tile)
    }

    /// 把应用的主窗口提到最前（AXRaise）。
    /// 只能越过同层级窗口；压不过别的应用设置的浮动层级窗口（例如 QQ 的置顶面板）。
    /// 用 AX 直接恢复（不让 Dock 参与），用于验证置顶是不是 Dock 恢复路径触发的
    private func axRestore(_ pid: pid_t) {
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        DockAX.restoreAll(pid: pid)
        usleep(150_000)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
        }
        usleep(250_000)
        let st = DockAX.windowStats(pid: pid)
        dlog("AX 恢复 \(name)：\(st.minimized)/\(st.total) 已恢复")
    }

    private func raiseApp(pid: pid_t) {
        // 刚收起过它就别再拉回来，否则会出现「先置顶、再点一下才最小化」的错乱
        if Date() < suppressRaiseUntil { return }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        // 已经在前台且没有最小化窗口 ⇒ 原生行为已经够好，不必再动
        let stats = DockAX.windowStats(pid: pid)
        if app.isActive && stats.total > 0 && stats.minimized == 0 { return }
        if !app.isActive { app.activate(options: []) }
        guard let w = DockAX.windows(pid: pid).first else { return }
        var mini: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mini) == .success,
           let b = mini as? Bool, b { return }      // 还最小化的交给系统恢复
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }

    private func act(_ tile: DockTile) {
        if isLauncher(tile) {
            closeLauncher()
            return
        }
        guard let app = NSRunningApplication(processIdentifier: tile.pid) else { return }

        // 先确保它真的成为前台：AX 动作只对 key window 生效，而我们的动作在 mouseUp 后
        // 十几毫秒就跑了，可能早于系统完成激活（Clash Verge 这类 app 因此时灵时不灵）
        if !app.isActive {
            app.activate(options: [])
            usleep(70_000)
        }
        // 一旦决定收起，就压住「提到最前」，避免延迟的 raise 又把它拉回来
        suppressRaiseUntil = Date().addingTimeInterval(1.2)

        switch Prefs.mode {
        case .hide:
            dlog("收起 \(tile.name)：\(hideApp(pid: tile.pid))")
        case .minimize:
            let r = minimizeAll(pid: tile.pid)
            dlog("收起 \(tile.name)：\(r)")
        }
        TileCache.shared.refresh()

    }

    /// 隐藏整个应用，四级回退（`hide()` 对 helper / Electron / Tauri 类 app 常直接返回 false）：
    ///   ① NSRunningApplication.hide()
    ///   ② 全局 ⌘H —— 走正常键盘事件流，前台 app 必收（Tauri 类不认 postToPid）
    ///   ③ ⌘H → postToPid
    ///   ④ AXHidden（放最后：部分 app 被置位后会自己弹回来，表现为「闪一下」）
    ///   ⑤ 全失败则降级为最小化，至少把窗口收走
    private func hideApp(pid: pid_t) -> String {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return "无进程" }
        if app.hide() { return "hide() 成功" }

        var report = ["hide()=false"]
        let el = AXUIElementCreateApplication(pid)

        postGlobalKey(code: 0x04, flags: .maskCommand)
        usleep(120_000)
        if isHidden(el, app) { return report.joined(separator: " / ") + " / 全局⌘H 成功" }
        report.append("全局⌘H 无效")

        sendKey(pid: pid, code: 0x04, flags: .maskCommand)
        usleep(110_000)
        if isHidden(el, app) { return report.joined(separator: " / ") + " / ⌘H→pid 成功" }
        report.append("⌘H→pid 无效")

        if AXUIElementSetAttributeValue(el, kAXHiddenAttribute as CFString, kCFBooleanTrue) == .success {
            usleep(90_000)
            if isHidden(el, app) { return report.joined(separator: " / ") + " / AXHidden 成功" }
        }
        report.append("AXHidden 无效")

        let m = minimizeAll(pid: pid)
        report.append("降级最小化：\(m)")
        return report.joined(separator: " / ")
    }

    private func isHidden(_ el: AXUIElement, _ app: NSRunningApplication) -> Bool {
        if app.isHidden { return true }
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXHiddenAttribute as CFString, &v) == .success,
           let b = v as? Bool { return b }
        return false
    }

    /// 关闭启动台：不用 Esc 打头（实测会把聚焦搜索唤起来）。
    /// 顺序：替身激活法（切前台）→ toggle 通知 → Esc（仅作最后手段）。
    private func closeLauncher() {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

        // ① 替身激活：激活别的应用再切回，覆盖层就收了
        dismissLauncher()
        usleep(120_000)
        if !launcherOverlayOpen() {
            dlog("关闭启动台：替身激活生效（\(ms())ms）")
            return
        }

        // ② Docklet 开关通知
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.launchpad.toggle"),
            object: nil, userInfo: nil, deliverImmediately: true)
        usleep(180_000)
        if !launcherOverlayOpen() {
            dlog("关闭启动台：toggle 通知生效（\(ms())ms）")
            return
        }

        // ③ 聚焦 + 程序坞 Esc（已知副作用：可能唤起聚焦搜索，故放最后）
        if let host = launcherHostPID() {
            sendKey(pid: host, code: 0x35)
        }
        if let dockPID = DockAX.dockPID() {
            sendKey(pid: dockPID, code: 0x35)
        }
        usleep(200_000)
        dlog("关闭启动台：Esc 兜底 overlayOpen=\(launcherOverlayOpen())（\(ms())ms）")
    }

    /// 全局按键（走正常事件流，前台 app 收到；仅用于「前台 app 自己」的菜单命令）
    private func postGlobalKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return }
        if !flags.isEmpty {
            d.flags = flags
            u.flags = flags
        }
        d.post(tap: .cghidEventTap)
        u.post(tap: .cghidEventTap)
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

        // 温和模式：只用 ⌘M，不按 AX 按钮、不置 AXMinimized。
        // 实测 Electron 系应用（QQ）被外部置 AXMinimized 后会把自己窗口重新设成浮动层级
        // （表现为「被置顶，别的程序盖不住」）。⌘M 是 app 自己的菜单命令，不会误按到别的按钮。
        let gentle = NSRunningApplication(processIdentifier: pid)?
            .bundleIdentifier.map { Prefs.gentleApps.contains($0) } ?? false
        if gentle {
            for i in 1...3 {
                sendCmdM(pid: pid)
                usleep(140_000)
                let (t, m) = DockAX.windowStats(pid: pid)
                if m >= t { return "⌘M 温和模式 \(i) 次→\(m)/\(t)" }
            }
            let (t, m) = DockAX.windowStats(pid: pid)
            return "⌘M 温和模式 3 次仍→\(m)/\(t)"
        }

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
    private func sendCmdM(pid: pid_t) { sendKey(pid: pid, code: 0x2E, flags: .maskCommand) }

    private func sendKey(pid: pid_t, code: CGKeyCode, flags: CGEventFlags = []) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return }
        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }
        down.postToPid(pid)
        up.postToPid(pid)
    }
}

// MARK: - 菜单栏

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var permissionTimer: DispatchSourceTimer?

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
        startPermissionWatcher()

        // 开机自启：默认开。每次启动对齐一次，app 被移动也能自愈
        AutoStart.sync()
        dlog("开机自启=\(Prefs.autoStart)，LaunchAgent 存在=\(AutoStart.installed)")

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

    /// 权限监视：`AXIsProcessTrusted` 的结果会被进程缓存，用户授权前启动的实例
    /// 不会自己变可信。这里每 2 秒复查一次，一旦授权就自动把监听拉起来，省掉手动重启。
    private func startPermissionWatcher() {
        guard permissionTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1.0, repeating: 2.0, leeway: .milliseconds(300))
        t.setEventHandler {
            guard Prefs.enabled, !ClickMonitor.shared.isRunning, axTrusted() else { return }
            if ClickMonitor.shared.start() {
                dlog("检测到授权已生效，监听自动启动")
            }
        }
        t.resume()
        permissionTimer = t
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

        // 顶部提示：**未开启时不说权限**，只说已停用 —— 否则用户手动关掉开关
        // 却看到满屏「未授权」，会以为出故障了
        if !Prefs.enabled {
            let it = NSMenuItem(title: "已停用（勾选「启用」恢复）", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        } else if !trusted {
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

        let auto = NSMenuItem(title: "开机自启", action: #selector(toggleAutoStart), keyEquivalent: "")
        auto.target = self
        auto.state = Prefs.autoStart ? .on : .off
        menu.addItem(auto)

        let raise = NSMenuItem(title: "唤出时提到最前", action: #selector(toggleRaise), keyEquivalent: "")
        raise.target = self
        raise.state = Prefs.raiseOnSummon ? .on : .off
        menu.addItem(raise)


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
        let stateText: String
        if !Prefs.enabled      { stateText = "已停用" }
        else if !trusted       { stateText = "缺权限（勾选「启用」后会提示授权）" }
        else if running        { stateText = "监听中 · " + detail }
        else                   { stateText = "已授权，未监听" }
        let state = NSMenuItem(title: "状态：" + stateText, action: nil, keyEquivalent: "")
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

    @objc private func toggleAutoStart() {
        Prefs.autoStart.toggle()
        AutoStart.sync()
        dlog("开机自启=\(Prefs.autoStart)，LaunchAgent 存在=\(AutoStart.installed)")
        rebuild()
    }

    @objc private func toggleRaise() {
        Prefs.raiseOnSummon.toggle()
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
        if let menus = DockAX.menuBarTitles(pid: pid) {
            dlog("   菜单: \(menus.joined(separator: " | "))")
        }
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

// 单实例：launchd 与手动 open 同时拉起时，只保留一个
let siblings = NSRunningApplication
    .runningApplications(withBundleIdentifier: "com.geekaudio.DockClickMin")
    .filter { $0.processIdentifier != getpid() }
if !siblings.isEmpty {
    dlog("已有实例在运行（pid=\(siblings[0].processIdentifier)），本次退出")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
