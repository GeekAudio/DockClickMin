// make_icon.swift — 从高清 PNG 主图生成 DockClickMin 的完整图标集
// 用法：swift assets/make_icon.swift <输出目录> [输入主图.png]
// 默认主图：本脚本所在目录的 logo-master.png；等比居中缩放，保留透明 alpha。

import Cocoa
import CoreGraphics
import ImageIO

struct IconBuildError: LocalizedError {
    let errorDescription: String?
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let outputURL = URL(fileURLWithPath: outDir, isDirectory: true)
let scriptURL = URL(fileURLWithPath: #filePath)
let inputURL = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : scriptURL.deletingLastPathComponent().appendingPathComponent("logo-master.png")
let iconsetURL = outputURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)

/// 在透明正方形画布内等比居中缩放，不添加背景、裁剪或重新绘制图案。
func writeIcon(_ source: CGImage, pixels: Int, to destinationURL: URL) throws {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil,
                                  width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconBuildError(errorDescription: "无法创建 \(pixels)px 图标画布")
    }

    let side = CGFloat(pixels)
    let sourceWidth = CGFloat(source.width)
    let sourceHeight = CGFloat(source.height)
    let scale = min(side / sourceWidth, side / sourceHeight)
    let width = sourceWidth * scale
    let height = sourceHeight * scale
    let frame = CGRect(x: (side - width) / 2, y: (side - height) / 2,
                       width: width, height: height)

    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.draw(source, in: frame)

    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw IconBuildError(errorDescription: "无法编码 \(destinationURL.lastPathComponent)")
    }
    try data.write(to: destinationURL, options: .atomic)
}

// 文件名和像素尺寸符合 iconutil 约定，包含所有 1x / 2x 版本。
let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

do {
    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width > 0, image.height > 0 else {
        throw IconBuildError(errorDescription: "无法读取输入主图：\(inputURL.path)")
    }

    try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    for spec in specs {
        try writeIcon(image, pixels: spec.pixels,
                      to: iconsetURL.appendingPathComponent(spec.name))
        print("生成 \(spec.name) (\(spec.pixels)px)")
    }

    try writeIcon(image, pixels: 1024,
                  to: outputURL.appendingPathComponent("icon-1024.png"))
    print("完成 → \(iconsetURL.path)")
} catch {
    FileHandle.standardError.write(Data("生成图标失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
