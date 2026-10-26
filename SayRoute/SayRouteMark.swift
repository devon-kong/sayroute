import AppKit

/// Native template rendering of the user-selected two-endpoint route mark.
/// AppKit supplies the correct monochrome tint in light and dark menu bars.
enum SayRouteMark {
    static func menuImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            let route = NSBezierPath()
            route.lineWidth = 2.15
            route.lineCapStyle = .round
            route.move(to: NSPoint(x: 12.2, y: 15))
            route.line(to: NSPoint(x: 8.5, y: 15))
            route.curve(to: NSPoint(x: 7.5, y: 11), controlPoint1: NSPoint(x: 5.2, y: 15), controlPoint2: NSPoint(x: 5.2, y: 12.7))
            route.line(to: NSPoint(x: 12.3, y: 7.2))
            route.curve(to: NSPoint(x: 10.8, y: 4.6), controlPoint1: NSPoint(x: 14.4, y: 5.5), controlPoint2: NSPoint(x: 13, y: 4.6))
            route.line(to: NSPoint(x: 7.8, y: 4.6))
            route.stroke()
            for rect in [NSRect(x: 12, y: 12, width: 6, height: 6), NSRect(x: 2, y: 1.6, width: 6, height: 6)] {
                let ring = NSBezierPath(ovalIn: rect)
                ring.lineWidth = 2.15
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SayRoute"
        return image
    }
}
