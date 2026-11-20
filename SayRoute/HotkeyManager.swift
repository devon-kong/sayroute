import Foundation
import Cocoa
import IOKit.hidsystem
import os

private let logger = Logger(subsystem: "com.devonkong.sayroute", category: "HotkeyManager")
private let functionKeyDiagnosticsLogger = Logger(
    subsystem: "com.devonkong.sayroute",
    category: "FunctionKeyDiagnostics"
)

struct StopHotkeyReleaseGate {
    private var shortcut: StartShortcut?
    private var keyIsDown = false

    mutating func begin(_ shortcut: StartShortcut) -> Bool {
        guard self.shortcut == nil else { return false }
        self.shortcut = shortcut
        keyIsDown = true
        return true
    }

    /// Evaluate the current flags, including any modifier pressed again before release.
    mutating func fullyReleased(after type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard let shortcut, type == .flagsChanged || keyCode == shortcut.keyCode else { return false }
        if keyCode == shortcut.keyCode {
            if type == .keyUp { keyIsDown = false }
            if type == .keyDown { keyIsDown = true }
        }
        guard !keyIsDown, flags.intersection(shortcut.modifiers).isEmpty else { return false }
        cancel()
        return true
    }

    mutating func cancel() {
        shortcut = nil
        keyIsDown = false
    }
}

enum PhysicalRightCommandEventFilter {
    static func isPhysicalRightCommand(keyCode: Int64, sourcePID: Int64) -> Bool {
        keyCode == 54 && sourcePID == 0
    }

    static func isPhysicalOrdinaryKeyDown(
        type: CGEventType,
        keyCode: Int64,
        sourcePID: Int64
    ) -> Bool {
        type == .keyDown && keyCode != 54 && sourcePID == 0
    }

    /// The ordinary key of a Command combo stays visible even when the input
    /// method consumes the physical right Command key-down itself.
    static func isCommandComboKeyDown(
        type: CGEventType,
        keyCode: Int64,
        sourcePID: Int64,
        flags: CGEventFlags
    ) -> Bool {
        isPhysicalOrdinaryKeyDown(type: type, keyCode: keyCode, sourcePID: sourcePID)
            && flags.contains(.maskCommand)
    }
}

class HotkeyManager: ObservableObject {
    enum HotkeyEvent {
        case toggleRecording
        case toggleHotkeyFullyReleased
        case physicalRightCommandStopDown
        case physicalRightCommandStopUp
        case physicalRightCommandStopInterruptedByOrdinaryKey
        case cancel
    }

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var functionKeyDiagnosticsTap: CFMachPort?
    private var functionKeyDiagnosticsRunLoopSource: CFRunLoopSource?
    private var accessibilityPollTimer: Timer?
    private var tapRetryCount = 0
    private let maxTapRetries = 30
    private var lastToggleTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.3
    private var stopComboMonitoringEnabled = false
    private var stopHotkeyReleaseGate = StopHotkeyReleaseGate()
    private var physicalRightCommandIsDown = false

    private let preferences: StartShortcutPreferences
    @Published private(set) var shortcut: StartShortcut
    @Published private(set) var interaction: ShortcutInteraction = .idle
    @Published private(set) var shortcutFeedback: String?
    @Published private(set) var sessionActive = false
    private weak var interactionWindow: NSWindow?
    private var localRecordingMonitor: Any?
    // Finish swallowing a captured/tested key after success or loss of settings focus.
    private var swallowedSettingsKeys: Set<Int64> = []

    var shortcutTitle: String { shortcut.title }
    var isListenerReady: Bool {
        listenerEnabled(eventTap) && listenerEnabled(functionKeyDiagnosticsTap)
    }

    private func listenerEnabled(_ tap: CFMachPort?) -> Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    init(defaults: UserDefaults = .standard) {
        let preferences = StartShortcutPreferences(defaults: defaults)
        self.preferences = preferences
        shortcut = preferences.shortcut
    }

    func start() {
        if !AXIsProcessTrusted() { requestAccessibilityPermission() }
        retryListener()
    }

    func retryListener() {
        guard !isListenerReady else { return }
        if installListeners() {
            accessibilityPollTimer?.invalidate()
            accessibilityPollTimer = nil
            tapRetryCount = 0
        } else if accessibilityPollTimer == nil {
            startPollingForEventTap()
        }
    }

    private func installListeners() -> Bool {
        for tap in [eventTap, functionKeyDiagnosticsTap].compactMap({ $0 }) where CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        if !listenerEnabled(eventTap) {
            removeListener(eventTap, source: runLoopSource)
            eventTap = nil
            runLoopSource = nil
            guard tryCreateEventTap() else { return false }
        }
        if !listenerEnabled(functionKeyDiagnosticsTap) {
            removeListener(functionKeyDiagnosticsTap, source: functionKeyDiagnosticsRunLoopSource)
            functionKeyDiagnosticsTap = nil
            functionKeyDiagnosticsRunLoopSource = nil
            createFunctionKeyDiagnosticsTap()
        }
        objectWillChange.send()
        return isListenerReady
    }

    private func removeListener(_ tap: CFMachPort?, source: CFRunLoopSource?) {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    private func tryCreateEventTap() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        objectWillChange.send()
        print("[HotkeyManager] ✅ Event tap started successfully")
        return true
    }

    private func createFunctionKeyDiagnosticsTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: functionKeyDiagnosticsCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            functionKeyDiagnosticsLogger.warning(
                "origin=hid_tap status=create_failed; main hotkey tap remains independent"
            )
            return
        }

        functionKeyDiagnosticsTap = tap
        functionKeyDiagnosticsRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func startPollingForEventTap() {
        accessibilityPollTimer?.invalidate()
        tapRetryCount = 0
        print("[HotkeyManager] ⏳ Polling for event tap creation (every 2s, max \(maxTapRetries) attempts)...")
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tapRetryCount += 1
            print("[HotkeyManager] 🔄 Retry \(self.tapRetryCount)/\(self.maxTapRetries) to create event tap...")

            if self.installListeners() {
                print("[HotkeyManager] ✅ Event tap created on retry \(self.tapRetryCount)")
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
                self.tapRetryCount = 0
                return
            }

            if self.tapRetryCount >= self.maxTapRetries {
                print("[HotkeyManager] ❌ Giving up after \(self.maxTapRetries) retries. Please remove and re-grant Accessibility permission, then restart the app.")
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
            }
        }
    }

    func stop() {
        settingsDidClose()
        stopHotkeyReleaseGate.cancel()
        physicalRightCommandIsDown = false
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        removeListener(functionKeyDiagnosticsTap, source: functionKeyDiagnosticsRunLoopSource)
        functionKeyDiagnosticsTap = nil
        functionKeyDiagnosticsRunLoopSource = nil
        removeListener(eventTap, source: runLoopSource)
        eventTap = nil
        runLoopSource = nil
        objectWillChange.send()
    }

    func setEscapeHandlingEnabled(_ isEnabled: Bool) {
        sessionActive = isEnabled
        if isEnabled { cancelShortcutInteraction() }
        logger.notice("ESC handling enabled: \(isEnabled)")
    }

    /// Command-combo interruption only matters while a session can be stopped
    /// by it. Without this gate every ⌘+keypress system-wide would surface as
    /// an interruption event.
    func setStopComboMonitoringEnabled(_ isEnabled: Bool) {
        stopComboMonitoringEnabled = isEnabled
    }

    func beginShortcutInteraction(_ mode: ShortcutInteraction) {
        guard mode != .idle, mode == .record || isListenerReady, !sessionActive,
              NSApp.isActive, let window = NSApp.keyWindow else { return }
        // App-local recording also works before Accessibility has been granted.
        // Testing always exercises the real global listener.
        if mode == .record, !listenerEnabled(eventTap), localRecordingMonitor == nil {
            localRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, !self.listenerEnabled(self.eventTap), let cgEvent = event.cgEvent else { return event }
                let handled = self.handleSettingsEvent(cgEvent.type, keyCode: Int64(event.keyCode),
                                                       flags: cgEvent.flags, isRepeat: event.isARepeat)
                return handled ? nil : event
            }
        }
        interactionWindow = window
        shortcutFeedback = nil
        interaction = mode
    }

    func cancelShortcutInteraction() {
        interaction = .idle
        shortcutFeedback = nil
        removeUnusedLocalMonitor()
    }

    private func removeUnusedLocalMonitor() {
        guard interaction == .idle, swallowedSettingsKeys.isEmpty else { return }
        interactionWindow = nil
        if let localRecordingMonitor { NSEvent.removeMonitor(localRecordingMonitor) }
        localRecordingMonitor = nil
    }

    func settingsWindowResigned(_ window: NSWindow?) {
        if let window, window === interactionWindow { settingsDidClose() }
    }

    func settingsDidClose() {
        swallowedSettingsKeys.removeAll()
        cancelShortcutInteraction()
    }

    func restoreDefaultShortcut() {
        guard !sessionActive else { return }
        cancelShortcutInteraction()
        saveShortcut(.standard)
        shortcutFeedback = "已恢复默认快捷键。"
    }

    private func saveShortcut(_ value: StartShortcut) {
        preferences.shortcut = value
        shortcut = value
    }

    private func handleSettingsEvent(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        if type == .keyUp {
            let handled = swallowedSettingsKeys.remove(keyCode) != nil
            removeUnusedLocalMonitor()
            return handled
        }
        guard type == .keyDown else { return false }
        if isRepeat && swallowedSettingsKeys.contains(keyCode) { return true }
        // A fresh press can follow a lost key-up when secure input was enabled.
        swallowedSettingsKeys.remove(keyCode)
        guard interaction != .idle else { return false }
        guard NSApp.isActive, interactionWindow?.isKeyWindow == true else {
            cancelShortcutInteraction()
            return false
        }
        swallowedSettingsKeys.insert(keyCode)
        if isRepeat { return true }
        switch interaction.keyDown(keyCode: keyCode, flags: flags, current: shortcut) {
        case .pass: return false
        case .cancel: cancelShortcutInteraction()
        case .pasteReserved: shortcutFeedback = "Command + V 用于粘贴听写结果，请选择其他组合键。"
        case .invalid: shortcutFeedback = "请同时按下 Control、Option 或 Command 和一个字母、数字或标点键，可加 Shift。"
        case let .save(value):
            cancelShortcutInteraction()
            saveShortcut(value)
            shortcutFeedback = "已保存新的启动快捷键。"
        case .testMiss: shortcutFeedback = "组合键不匹配，请按 " + shortcutTitle + "。"
        case .testPassed:
            shortcutFeedback = "测试成功，已识别启动快捷键。可继续试按，或结束测试。"
        }
        return true
    }

    func cancelStopHotkeyReleaseTracking() {
        stopHotkeyReleaseGate.cancel()
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            print("[HotkeyManager] Accessibility permission not granted. Please enable it in System Settings > Privacy & Security > Accessibility.")
        }
    }

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Re-enable the tap
            logger.warning("Event tap was disabled (type=\(type.rawValue)), re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 63 || keyCode == 54 { // kVK_Function / kVK_RightCommand
            let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            functionKeyDiagnosticsLogger.notice(
                "origin=event_tap eventType=\(type.rawValue, privacy: .public) flags=\(event.flags.rawValue, privacy: .public) keyCode=\(keyCode, privacy: .public) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID), privacy: .public) sourceState=\(event.getIntegerValueField(.eventSourceStateID), privacy: .public) keyboardType=\(event.getIntegerValueField(.keyboardEventKeyboardType), privacy: .public) frontmostBundle=\(frontmostBundleIdentifier, privacy: .public)"
            )
        }
        if stopHotkeyReleaseGate.fullyReleased(after: type, keyCode: keyCode, flags: event.flags) {
            logger.notice("event=toggle_hotkey_fully_released")
            onHotkeyEvent?(.toggleHotkeyFullyReleased)
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if handleSettingsEvent(type, keyCode: keyCode, flags: event.flags, isRepeat: isRepeat) { return nil }

        if type == .keyDown {
            if shortcut.matches(keyCode: keyCode, flags: event.flags) {
                guard isListenerReady else { return Unmanaged.passUnretained(event) }
                let now = ProcessInfo.processInfo.systemUptime
                if !isRepeat && now - lastToggleTime > debounceInterval {
                    lastToggleTime = now
                    _ = stopHotkeyReleaseGate.begin(shortcut)
                    logger.notice("event=toggle_hotkey_pressed")
                    onHotkeyEvent?(.toggleRecording)
                }
                return nil
            }

            // ESC key
            if keyCode == 53 {
                logger.notice(
                    "ESC pressed (keyCode=53, handler set: \(self.onHotkeyEvent != nil), shouldConsume: \(self.sessionActive))"
                )
                guard sessionActive else {
                    return Unmanaged.passUnretained(event)
                }
                onHotkeyEvent?(.cancel)
                return nil // Consume ESC when we handle it
            }
        }

        return Unmanaged.passUnretained(event)
    }

    fileprivate func handleFunctionKeyDiagnosticsEvent(
        _ type: CGEventType,
        _ event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = functionKeyDiagnosticsTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let isPhysicalRightCommand = PhysicalRightCommandEventFilter.isPhysicalRightCommand(
            keyCode: keyCode,
            sourcePID: sourcePID
        )
        if keyCode == 63 || keyCode == 54 || event.flags.contains(.maskSecondaryFn) {
            let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            functionKeyDiagnosticsLogger.notice(
                "origin=hid_tap eventType=\(type.rawValue, privacy: .public) flags=\(event.flags.rawValue, privacy: .public) keyCode=\(keyCode, privacy: .public) sourcePID=\(sourcePID, privacy: .public) sourceState=\(event.getIntegerValueField(.eventSourceStateID), privacy: .public) keyboardType=\(event.getIntegerValueField(.keyboardEventKeyboardType), privacy: .public) frontmostBundle=\(frontmostBundleIdentifier, privacy: .public)"
            )
        }

        guard interaction == .idle else {
            physicalRightCommandIsDown = false
            return Unmanaged.passUnretained(event)
        }

        let leftCommandOnly = event.flags.rawValue & UInt64(NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK)
            == UInt64(NX_DEVICELCMDKEYMASK)
        if isPhysicalRightCommand, type == .flagsChanged {
            if event.flags.contains(.maskCommand) {
                physicalRightCommandIsDown = true
                functionKeyDiagnosticsLogger.notice("event=physical_right_command_stop_down")
                onHotkeyEvent?(.physicalRightCommandStopDown)
            } else {
                physicalRightCommandIsDown = false
                functionKeyDiagnosticsLogger.notice("event=physical_right_command_stop_up")
                onHotkeyEvent?(.physicalRightCommandStopUp)
            }
        } else if PhysicalRightCommandEventFilter.isPhysicalOrdinaryKeyDown(
                      type: type,
                      keyCode: keyCode,
                      sourcePID: sourcePID
                  ),
                  physicalRightCommandIsDown
                      || (stopComboMonitoringEnabled
                          && !(leftCommandOnly && shortcut.matches(keyCode: keyCode, flags: event.flags))
                          && PhysicalRightCommandEventFilter.isCommandComboKeyDown(
                              type: type,
                              keyCode: keyCode,
                              sourcePID: sourcePID,
                              flags: event.flags
                          )) {
            functionKeyDiagnosticsLogger.notice(
                "event=physical_right_command_stop_interrupted keyCode=\(keyCode, privacy: .public)"
            )
            onHotkeyEvent?(.physicalRightCommandStopInterruptedByOrdinaryKey)
        }
        return Unmanaged.passUnretained(event)
    }
}

// C callback for CGEvent tap
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(proxy, type, event)
}

private func functionKeyDiagnosticsCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleFunctionKeyDiagnosticsEvent(type, event)
}
