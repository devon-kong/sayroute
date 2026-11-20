import AppKit
import ApplicationServices
import Combine

@MainActor
final class UUWindowObserver: NSObject {
    let router = UUWindowRouter()
    private var app: NSRunningApplication?
    private var observer: AXObserver?
    private var retries: [AXUIElement: Task<Void, Never>] = [:]
    private let workspace = NSWorkspace.shared
    private var enabled = false
    private var modeSubscription: AnyCancellable?

    func start() {
        guard modeSubscription == nil else { return }
        modeSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMode() }
        updateMode()
    }

    func stop() {
        modeSubscription = nil
        workspace.notificationCenter.removeObserver(self)
        enabled = false
        detach()
    }

    private func updateMode() {
        guard modeSubscription != nil else { return }
        let direct = PasteRoutingSettings().uuPasteMode == .direct
        guard direct != enabled else { return }
        enabled = direct
        if direct {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                         NSWorkspace.didTerminateApplicationNotification] {
                workspace.notificationCenter.addObserver(self, selector: #selector(applicationEvent(_:)),
                                                         name: name, object: nil)
            }
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: PasteRouter.uuBundleIdentifier).first {
                attach(to: running)
            }
        } else {
            workspace.notificationCenter.removeObserver(self)
            detach()
        }
    }

    @objc private func applicationEvent(_ notification: Notification) {
        guard enabled, let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              running.bundleIdentifier == PasteRouter.uuBundleIdentifier else { return }
        if notification.name == NSWorkspace.didTerminateApplicationNotification {
            if app?.processIdentifier == running.processIdentifier { detach() }
        } else { attach(to: running) }
    }

    func capture(for running: NSRunningApplication?) -> Task<UUTarget, Error> {
        updateMode()
        if let running, running.bundleIdentifier == PasteRouter.uuBundleIdentifier { attach(to: running) }
        let bindings = UUBindingStore().bindings
        let focused = UUWindowSnapshot.capture(for: running, knownNames: Set(bindings.map(\.name)))
        return router.destination(for: focused, bindings: bindings)
    }

    private func attach(to running: NSRunningApplication) {
        guard enabled, !running.isTerminated else { return }
        if app?.processIdentifier != running.processIdentifier || app?.isTerminated == true { detach() }
        app = running
        guard observer == nil, AXIsProcessTrusted() else { return }
        let pid = running.processIdentifier
        var result: AXObserver?
        let status = AXObserverCreate(pid, { observer, element, name, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let owner = Unmanaged<UUWindowObserver>.fromOpaque(context).takeUnretainedValue()
                guard let current = owner.observer, CFEqual(current, observer) else { return }
                owner.handle(element, event: name as String)
            }
        }, &result)
        guard status == .success, let result else { return }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let events = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                      kAXWindowResizedNotification, kAXUIElementDestroyedNotification]
        let registered = events.map { AXObserverAddNotification(result, root, $0 as CFString, context) }
        guard registered.prefix(2).contains(.success) else { return }
        observer = result
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
        if let windows = UUWindowSnapshot.read(root, kAXWindowsAttribute) as? [AXUIElement] {
            for window in windows { discover(window) }
        }
    }

    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        app = nil
        for retry in retries.values { retry.cancel() }
        retries.removeAll()
        router.reset()
    }

    private func handle(_ element: AXUIElement, event: String) {
        if event == kAXUIElementDestroyedNotification {
            retries.removeValue(forKey: element)?.cancel()
            router.forget(element)
            return
        }
        if event == kAXWindowCreatedNotification { router.forget(element) }
        guard !router.knows(element) else { return }
        if UUWindowSnapshot.read(element, kAXRoleAttribute) as? String == kAXApplicationRole {
            if let focused = UUWindowSnapshot.focusedWindow(of: element) { discover(focused) }
        } else { discover(element) }
    }

    private func discover(_ window: AXUIElement) {
        guard !router.knows(window), retries[window] == nil else { return }
        if inspectForBinding(window) { return }
        // A new window can briefly expose an empty or placeholder device name.
        guard (UUWindowSnapshot.read(window, kAXTitleAttribute) as? String ?? "").isEmpty,
              retries.count < 32 else { return }
        retries[window] = Task { [weak self] in
            for delay in [120, 280, 600, 1000] {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.router.knows(window) || self.inspectForBinding(window) { break }
            }
            self?.retries.removeValue(forKey: window)
        }
    }

    private func inspectForBinding(_ window: AXUIElement) -> Bool {
        guard let snapshot = UUWindowSnapshot.inspect(window) else { return false }
        if snapshot.isFullscreen { return true }
        guard snapshot.label != nil else { return false }
        router.learn(snapshot)
        return true
    }
}
