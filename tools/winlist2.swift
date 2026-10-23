import Cocoa
let arr = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in arr {
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    guard pid == 657 else { continue }
    let name = w[kCGWindowName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let b = w[kCGWindowBounds as String] as? NSDictionary
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
    print("聚焦窗口: name=\"\(name)\" layer=\(layer) alpha=\(String(format: "%.2f", alpha)) bounds=\(b?.description ?? "-")")
}
