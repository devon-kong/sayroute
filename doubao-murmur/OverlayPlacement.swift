import AppKit
import ApplicationServices

enum OverlayPositionMode: String, CaseIterable {
    case followMouse
    case screenTop

    var title: String { self == .followMouse ? "跟随鼠标坐标" : "屏幕上方" }
}

struct OverlayPlacementSettings {
    static let defaultsKey = "overlayPositionMode"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var mode: OverlayPositionMode {
        get { defaults.string(forKey: Self.defaultsKey).flatMap(OverlayPositionMode.init(rawValue:)) ?? .followMouse }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.defaultsKey) }
    }
}

struct OverlayDisplay: Equatable {
    let id: UInt32
    let frame: NSRect
    let visibleFrame: NSRect

    @MainActor static var current: [OverlayDisplay] {
        NSScreen.screens.map {
            OverlayDisplay(id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                           frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
    }
}

/// Immutable per-session policy and anchor; layout can adapt to display removal,
/// but later settings or mouse movement must not relabel an older notification.
struct OverlayPlacementContext: Equatable {
    let mode: OverlayPositionMode
    let anchor: NSPoint
    let displayID: UInt32?

    init(mode: OverlayPositionMode, anchor: NSPoint, displays: [OverlayDisplay]) {
        self.mode = mode
        self.anchor = anchor
        self.displayID = Self.nearestDisplay(to: anchor, in: displays)?.id
    }

    @MainActor static func capture() -> OverlayPlacementContext {
        OverlayPlacementContext(mode: OverlayPlacementSettings().mode, anchor: NSEvent.mouseLocation,
                                displays: OverlayDisplay.current)
    }

    func frame(height: CGFloat, displays: [OverlayDisplay]) -> NSRect {
        let screen = displays.first { $0.id == displayID } ?? Self.nearestDisplay(to: anchor, in: displays)
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return OverlayGeometry.frame(in: visible, height: height, mode: mode, anchor: anchor)
    }

    private static func nearestDisplay(to point: NSPoint, in screens: [OverlayDisplay]) -> OverlayDisplay? {
        if let screen = screens.first(where: { $0.frame.contains(point) }) { return screen }
        func distance(_ r: NSRect) -> CGFloat {
            let dx = max(r.minX - point.x, 0, point.x - r.maxX)
            let dy = max(r.minY - point.y, 0, point.y - r.maxY)
            return dx * dx + dy * dy
        }
        return screens.min { distance($0.frame) < distance($1.frame) }
    }
}

enum OverlayGeometry {
    static func frame(in screen: NSRect, height: CGFloat) -> NSRect {
        frame(in: screen, height: height, mode: .screenTop, anchor: .zero)
    }

    static func frame(in screen: NSRect, height: CGFloat, mode: OverlayPositionMode, anchor: NSPoint) -> NSRect {
        let margin = min(12, max(0, min(screen.width, screen.height) / 4))
        let safe = screen.insetBy(dx: margin, dy: margin)
        let width = min(420, max(0, safe.width)), height = min(height, max(0, safe.height))
        var x = mode == .screenTop ? screen.midX - width / 2 : anchor.x - width / 3
        var y = mode == .screenTop ? screen.maxY - 20 - height : anchor.y
        if mode == .followMouse, y + height > safe.maxY { y = anchor.y - height }
        x = min(max(x, safe.minX), safe.maxX - width)
        y = min(max(y, safe.minY), safe.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

struct RecoveryNotice: Equatable {
    let message: String
    let placement: OverlayPlacementContext
}

enum OverlayZoomSupport {
    static func request(frame: NSRect, primaryScreenTop: CGFloat, mode: OverlayPositionMode,
                        enabled: Bool, notify: (CGRect) -> Void) {
        guard mode == .followMouse, enabled else { return }
        // AppKit uses bottom-left screen coordinates; Universal Access uses
        // global CoreGraphics points, flipped around the primary display top.
        notify(CGRect(x: frame.minX, y: primaryScreenTop - frame.maxY, width: frame.width, height: frame.height))
    }

    @MainActor static func reveal(frame: NSRect, mode: OverlayPositionMode) {
        guard let primary = NSScreen.screens.first else { return }
        request(frame: frame, primaryScreenTop: primary.frame.maxY, mode: mode, enabled: UAZoomEnabled()) { rect in
            var rect = rect
            // This is a focus hint, not a visibility guarantee or a change to
            // the user's zoom factor/preferences. Never call on every character.
            _ = UAZoomChangeFocus(&rect, nil, UInt32(kUAZoomFocusTypeOther))
        }
    }
}
