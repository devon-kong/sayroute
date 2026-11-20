import AppKit
import ApplicationServices

/// Only UU's local window and its device-name label are inspected.
struct UUWindowSnapshot {
    let window: AXUIElement
    let label: String?
    let isFullscreen: Bool
    let capturedAt: Date

    @MainActor static func capture(for app: NSRunningApplication?, knownNames: Set<String>? = nil) -> Self? {
        guard let app, app.bundleIdentifier == PasteRouter.uuBundleIdentifier, app.isActive else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let window = focusedWindow(of: root), let snapshot = inspect(window, knownNames: knownNames),
              let final = focusedWindow(of: root), CFEqual(window, final),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              !app.isTerminated else { return nil }
        return snapshot
    }

    static func inspect(_ window: AXUIElement, knownNames: Set<String>? = nil) -> Self? {
        AXUIElementSetMessagingTimeout(window, 0.15)
        guard read(window, kAXRoleAttribute) as? String == kAXWindowRole,
              read(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              read(window, kAXTitleAttribute) as? String == "" else { return nil }
        if read(window, "AXFullScreen") as? Bool == true {
            // An anonymous fullscreen window can only use an existing binding
            // for this exact AX element. Its controls and statistics are irrelevant.
            return Self(window: window, label: nil, isFullscreen: true, capturedAt: Date())
        }
        guard let children = read(window, kAXChildrenAttribute) as? [AXUIElement],
              children.count <= 48 else { return nil }
        var roles: [String] = []
        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.15)
            guard let role = read(child, kAXRoleAttribute) as? String else { return nil }
            roles.append(role)
        }
        guard UUWindowCapture.isRemoteWindow(title: "", roles: roles) else { return nil }
        let names = knownNames ?? Set(UUBindingStore().bindings.map(\.name))
        let label = UUWindowCapture.deviceName(title: "", roles: roles, knownNames: names) { index in
            read(children[index], kAXValueAttribute) as? String
        }
        return Self(window: window, label: label, isFullscreen: false, capturedAt: Date())
    }

    static func focusedWindow(of root: AXUIElement) -> AXUIElement? {
        guard let value = read(root, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
