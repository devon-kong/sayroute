#!/usr/bin/swift
// Packaging artwork only. Does not read or modify the application's icon.
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: render-dmg-background.swift OUTPUT.png\n", stderr)
    exit(64)
}
let width = 640, height = 420, scale = 2
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
    pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
// Finder uses top-left coordinates. Align with the icons' visual centers.
let arrowY: CGFloat = CGFloat(height) - 196
NSColor(calibratedWhite: 0.56, alpha: 1).setStroke()
let shaft = NSBezierPath()
shaft.lineWidth = 2
shaft.setLineDash([5, 6], count: 2, phase: 0)
shaft.move(to: NSPoint(x: 268, y: arrowY))
shaft.line(to: NSPoint(x: 366, y: arrowY))
shaft.stroke()
let head = NSBezierPath()
head.lineWidth = 2
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: NSPoint(x: 357, y: arrowY + 8))
head.line(to: NSPoint(x: 367, y: arrowY))
head.line(to: NSPoint(x: 357, y: arrowY - 8))
head.stroke()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode DMG background\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
} catch {
    fputs("Could not write DMG background: \(error)\n", stderr)
    exit(1)
}
