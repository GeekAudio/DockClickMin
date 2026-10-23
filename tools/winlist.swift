// 列出所有在屏窗口的 owner/pid/layer/alpha/rect，用来判断某个窗口是否被"置顶"（layer > 0）
import Cocoa
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
print("窗口总数:", list.count)
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let b = w[kCGWindowBounds as String] as? NSDictionary
    let x = (b?["X"] as? Double) ?? -1, y = (b?["Y"] as? Double) ?? -1
    let ww = (b?["Width"] as? Double) ?? -1, hh = (b?["Height"] as? Double) ?? -1
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
    print("owner=\(owner) pid=\(pid) layer=\(layer) alpha=\(String(format: "%.2f", alpha)) rect=\(Int(x)),\(Int(y)) \(Int(ww))x\(Int(hh))")
}
