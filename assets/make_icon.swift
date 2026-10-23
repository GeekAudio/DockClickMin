// make_icon.swift — 生成 DockClickMin 的 AppIcon.iconset
// 用法：swift make_icon.swift <输出目录>
// 设计：macOS 圆角方块 + 蓝色渐变底；下方是 Dock 条（三格），上方白色向下箭头指向 Dock
//       —— 语义就是「把窗口送进 Dock 图标」

import Cocoa
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = (outDir as NSString).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

/// 在 1024×1024 的画布上绘制（坐标系原点左下）
func drawIcon(size: CGFloat, to path: String) {
    let scale = size / 1024.0
    guard let ctx = CGContext(data: nil,
                              width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // ---- 背景：macOS 圆角方块（内容区 824，四周留 100） ----
    let content = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bgPath = CGPath(roundedRect: content, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(bgPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.40, green: 0.53, blue: 1.00, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.16, green: 0.20, blue: 0.66, alpha: 1).cgColor] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(g,
                               start: CGPoint(x: 512, y: 924),
                               end: CGPoint(x: 512, y: 100),
                               options: [])
    }
    ctx.restoreGState()

    // ---- Dock 条 ----
    let barRect = CGRect(x: 212, y: 250, width: 600, height: 96)
    let bar = CGPath(roundedRect: barRect, cornerWidth: 48, cornerHeight: 48, transform: nil)
    ctx.addPath(bar)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.94).cgColor)
    ctx.fillPath()

    // 条里的三个小格
    let cellY: CGFloat = 266
    for i in 0..<3 {
        let x = 384 + CGFloat(i) * 128
        let cell = CGRect(x: x, y: cellY, width: 64, height: 64)
        ctx.addPath(CGPath(roundedRect: cell, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.setFillColor(NSColor(srgbRed: 0.20, green: 0.26, blue: 0.72, alpha: 0.90).cgColor)
        ctx.fillPath()
    }

    // ---- 向下的箭头（指向 Dock）：粗胖 + 圆角 ----
    // 做法：画多边形，再用同色圆角描边 + 填充。描边半径把每个尖角磨圆，
    // 形状整体外扩 r，所以多边形本身按 r 内缩。
    let r: CGFloat = 28
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 456, y: 842))     // 轴左上
    arrow.addLine(to: CGPoint(x: 568, y: 842))   // 轴右上
    arrow.addLine(to: CGPoint(x: 568, y: 700))   // 轴右下
    arrow.addLine(to: CGPoint(x: 664, y: 700))   // 头右
    arrow.addLine(to: CGPoint(x: 512, y: 560))   // 尖
    arrow.addLine(to: CGPoint(x: 360, y: 700))   // 头左
    arrow.addLine(to: CGPoint(x: 456, y: 700))   // 轴左下
    arrow.closeSubpath()

    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineWidth(r * 2)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.addPath(arrow)
    ctx.strokePath()
    ctx.addPath(arrow)
    ctx.fillPath()

    // ---- 顶部高光 ----
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 640),
                           options: [])
    ctx.restoreGState()

    guard let img = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

// 需要的尺寸（文件名必须符合 iconutil 约定）
let specs: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for s in specs {
    let p = (iconset as NSString).appendingPathComponent(s.name)
    drawIcon(size: s.px, to: p)
    print("生成 \(s.name) (\(Int(s.px))px)")
}

// 顺便导一张 1024 的主图，给 README 用
drawIcon(size: 1024, to: (outDir as NSString).appendingPathComponent("icon-1024.png"))
print("完成 → \(iconset)")
