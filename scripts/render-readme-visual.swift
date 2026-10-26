// Generates a documentation illustration, not an operating-system screenshot.
// Visual source: SayRoute/OverlayView.swift, RecoveryWindow.swift,
// SessionDraftStore.swift and SayRouteMark.swift. All text entries are examples.
// Run from the repository root: swift scripts/render-readme-visual.swift
import AppKit

let width: CGFloat = 1240, height: CGFloat = 790, scale: CGFloat = 2
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
    pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
cg.scaleBy(x: scale, y: scale)
cg.translateBy(x: 0, y: height)
cg.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let ink = color(0x171A1E), secondary = color(0x727A83), line = color(0xE0E4E8)
func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
         radius: CGFloat = 0, fill: NSColor, stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius)
    fill.setFill(); path.fill()
    if let stroke { stroke.setStroke(); path.lineWidth = 0.7; path.stroke() }
}
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
          size: CGFloat = 15, weight: NSFont.Weight = .regular, tint: NSColor? = nil,
          alignment: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment; style.lineSpacing = 3
    style.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: tint ?? ink, .paragraphStyle: style]
    (value as NSString).draw(in: NSRect(x: x, y: y, width: w, height: h), withAttributes: attrs)
}
func circle(_ x: CGFloat, _ y: CGFloat, _ diameter: CGFloat, _ fill: NSColor) {
    fill.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
}
func rule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) { box(x, y, w, 1, fill: line) }
func mark(_ x: CGFloat, _ y: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: x, yBy: y); t.concat()
    let path = NSBezierPath(); path.lineWidth = 5; path.lineCapStyle = .round
    path.move(to: NSPoint(x: 32, y: 13)); path.line(to: NSPoint(x: 23, y: 13))
    path.curve(to: NSPoint(x: 20, y: 24), controlPoint1: NSPoint(x: 14, y: 13), controlPoint2: NSPoint(x: 13, y: 19))
    path.line(to: NSPoint(x: 32, y: 34))
    path.curve(to: NSPoint(x: 27, y: 43), controlPoint1: NSPoint(x: 38, y: 40), controlPoint2: NSPoint(x: 34, y: 43))
    path.line(to: NSPoint(x: 19, y: 43)); ink.setStroke(); path.stroke()
    for rect in [NSRect(x: 31, y: 5, width: 16, height: 16), NSRect(x: 3, y: 35, width: 16, height: 16)] {
        let ring = NSBezierPath(ovalIn: rect); ring.lineWidth = 5; ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
}

// Editorial framing is outside the illustrated application windows.
box(0, 0, width, height, fill: color(0xF5F6F8))
mark(48, 48)
text("SayRoute", 118, 47, 700, 61, size: 45, weight: .semibold)
text("Speak here. Type there.", 120, 112, 700, 30, size: 22, tint: secondary)
box(1006, 64, 186, 34, radius: 17, fill: .white, stroke: line)
text("1.4.0 · PREVIEW", 1006, 72, 186, 20, size: 12, weight: .semibold, tint: secondary, alignment: .center)
rule(48, 174, 1144)

text("01  /  DICTATION", 48, 209, 420, 24, size: 12, weight: .semibold, tint: secondary)
text("02  /  RECOVERY", 572, 209, 620, 24, size: 12, weight: .semibold, tint: secondary)

// OverlayView: 420pt panel, radius 16, 18pt horizontal padding,
// 8pt state dot, 12pt HStack gap, 15pt editor text and a waiting caption.
box(48, 256, 420, 76, radius: 16, fill: color(0xFFFFFF), stroke: line)
circle(66, 289, 8, color(0xF3A528))
text("说出的文字，送到正确的位置。", 86, 267, 362, 23, size: 15)
text("Speak here. Type there.", 86, 288, 362, 21, size: 15)
text("仍在等待输入法提交，超时会保留文字。", 86, 311, 362, 17, size: 11, tint: secondary)
text("Wait for the final text.", 48, 365, 420, 34, size: 25, weight: .medium)
text("The panel keeps the text visible while the\ninput method finishes its composition.", 48, 411, 420, 58, size: 16, tint: secondary)
rule(48, 496, 420)
text("THREE DELIVERY ROUTES", 48, 524, 420, 22, size: 11, weight: .semibold, tint: secondary)
for (index, label) in ["Local apps", "UU compatibility", "UU fast"].enumerated() {
    let y: CGFloat = 560 + CGFloat(index) * 38
    circle(49, y + 7, 5, ink)
    text(label, 68, y, 380, 25, size: 16)
}

// RecoveryWindowController: 620 x 460pt content, titlebar shown separately.
// The actual app is Chinese-only today; those UI labels remain in Chinese.
box(572, 256, 620, 460, radius: 10, fill: .white, stroke: color(0xD6DBE1))
box(573, 257, 618, 36, radius: 9, fill: color(0xF0F1F3))
box(573, 278, 618, 15, fill: color(0xF0F1F3))
circle(587, 269, 11, color(0xFF6058)); circle(606, 269, 11, color(0xD9DCE0)); circle(625, 269, 11, color(0x30C64B))
text("最近文字与恢复", 748, 266, 270, 22, size: 13, weight: .semibold, alignment: .center)
rule(573, 292, 618)
text("文字按需从加密临时文件读取，退出或重启后不恢复。", 590, 312, 584, 24, size: 13, tint: secondary)
text("最多20条、最长3天。打开窗口清除已有提醒，失败状态和记录仍保留。", 590, 344, 584, 20, size: 11, tint: secondary)

func entry(y: CGFloat, time: String, route: String, status: String, statusColor: NSColor, sample: String) {
    box(590, y, 584, 132, radius: 8, fill: color(0xF5F5F6))
    text(time, 602, y + 12, 66, 18, size: 11, tint: secondary)
    text(route, 674, y + 12, 280, 18, size: 11, tint: secondary)
    box(1057, y + 9, 46, 23, radius: 5, fill: .white, stroke: line)
    text("复制", 1057, y + 12, 46, 18, size: 12, alignment: .center)
    box(1111, y + 9, 46, 23, radius: 5, fill: .white, stroke: line)
    text("删除", 1111, y + 12, 46, 18, size: 12, tint: color(0xCB4542), alignment: .center)
    text(status, 602, y + 42, 560, 35, size: 13, tint: statusColor)
    text(sample, 602, y + 79, 552, 45, size: 14)
}
entry(y: 384, time: "09:42", route: "UU 快速模式",
      status: "结果未知：网络中断或等待回执超时。先检查目标，避免重复。",
      statusColor: color(0xBC6C10), sample: "这是一段演示文字。连接中断时，先检查目标输入框，再决定是否手动复制。")
entry(y: 532, time: "09:41", route: "本机",
      status: "已投递按键；请以目标输入框为准", statusColor: secondary,
      sample: "在这里说，在目标位置输入。\nSpeak here. Type there.")
text("Code-rendered UI illustration · Sample text · Current interface uses Chinese", 48, 750, 1144, 22,
     size: 12, tint: secondary)

NSGraphicsContext.current = nil
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/visuals/sayroute-interface.png"
try FileManager.default.createDirectory(at: URL(fileURLWithPath: output).deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Rendered \(Int(width * scale)) × \(Int(height * scale)): \(output)")
