import AppKit

// 生成 AppIcon.iconset（各尺寸 PNG），配合 iconutil 产出 .icns
// 用法: swift scripts/icon.swift <iconset输出目录>

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1]
                 : "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func draw(_ px: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let inset = CGFloat(px) * 0.06
    let rect = NSRect(x: 0, y: 0, width: px, height: px).insetBy(dx: inset, dy: inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: CGFloat(px) * 0.2, yRadius: CGFloat(px) * 0.2)
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.15, green: 0.42, blue: 0.85, alpha: 1.0),
        NSColor(srgbRed: 0.05, green: 0.12, blue: 0.42, alpha: 1.0)
    ])!
    grad.draw(in: path, angle: -90)

    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: CGFloat(px) * 0.52, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para
    ]
    ("并" as NSString).draw(
        in: NSRect(x: 0, y: CGFloat(px) * 0.26, width: CGFloat(px), height: CGFloat(px) * 0.62),
        withAttributes: attrs
    )
    img.unlockFocus()
    return img
}

let sizes: [(px: Int, scale: Int)] = [
    (16, 1), (32, 2), (32, 1), (64, 2),
    (128, 1), (256, 2), (256, 1), (512, 2),
    (512, 1), (1024, 2)
]

for (px, scale) in sizes {
    let img = draw(px)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(px)x\(px).png" : "icon_\(px / 2)x\(px / 2)@2x.png"
    try? png.write(to: outDir.appendingPathComponent(name))
}
print("iconset written to \(outDir.path)")
