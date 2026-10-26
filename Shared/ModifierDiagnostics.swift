import CoreGraphics
import Foundation

enum ModifierDiagnostics {
    static let build = "1.3.1 (19)"
    static let strategy = "preflight-snapshot-v2"

    static func preparedDetails(_ flags: BalancedPasteKeys.PreparedFlags) -> String {
        encode([
            "initial_hid_flags": flags.initialHID.rawValue,
            "initial_session_flags": flags.initialSession.rawValue,
            "prepared_down_flags": flags.down.rawValue,
            "prepared_up_flags": flags.up.rawValue,
            "strategy": strategy
        ])
    }

    /// Observational only: never delays ACK or changes the user's keyboard state.
    static func schedulePostDispatch(result: BalancedPasteKeys.Result,
                                     schedule: (TimeInterval, @escaping () -> Void) -> Void,
                                     capture: @escaping () -> Void) {
        guard result == .posted else { return }
        schedule(0.05, capture)
    }

    static func keyClass(type: CGEventType, keyCode: Int64) -> String? {
        if type == .flagsChanged {
            if keyCode == 54 { return "right_command" }
            if keyCode == 55 { return "left_command" }
            if [56, 60, 58, 61, 59, 62].contains(keyCode) { return "other_modifier" }
            return nil
        }
        guard type == .keyDown || type == .keyUp else { return nil }
        switch keyCode {
        case 49: return "space"
        case 51, 117: return "delete"
        case 9: return "paste_key"
        case 0: return "test_character"
        default: return nil
        }
    }

    static func snapshot(stage: String) -> String {
        encode([
            "stage": stage, "helper_build": build, "paste_key_strategy": strategy,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "utc_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "monotonic_ns": DispatchTime.now().uptimeNanoseconds,
            "hid_flags": CGEventSource.flagsState(.hidSystemState).rawValue,
            "session_flags": CGEventSource.flagsState(.combinedSessionState).rawValue,
            "left_command_hid": CGEventSource.keyState(.hidSystemState, key: 55),
            "right_command_hid": CGEventSource.keyState(.hidSystemState, key: 54),
            "left_command_session": CGEventSource.keyState(.combinedSessionState, key: 55),
            "right_command_session": CGEventSource.keyState(.combinedSessionState, key: 54)
        ])
    }

    private static func encode(_ fields: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Explicit, bounded, listen-only acceptance tool. Never reads Unicode text.
    static func run(seconds: TimeInterval) -> Int32 {
        guard seconds >= 1, seconds <= 120 else { return 64 }
        let observer = ModifierObserver()
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: modifierDiagnosticCallback,
            userInfo: Unmanaged.passUnretained(observer).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            fputs("Cannot observe modifiers. Check permission for the installed murmur-mirror executable.\n", stderr)
            return 2
        }
        observer.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        print(snapshot(stage: "diagnostic_started")); fflush(stdout)
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        withExtendedLifetime(observer) {
            while ProcessInfo.processInfo.systemUptime < deadline {
                CFRunLoopRunInMode(.defaultMode, min(0.5, deadline - ProcessInfo.processInfo.systemUptime), false)
            }
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        CFMachPortInvalidate(tap)
        print(snapshot(stage: "diagnostic_finished")); fflush(stdout)
        return 0
    }

    fileprivate static func record(type: CGEventType, event: CGEvent) {
        guard let kind = keyClass(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode)) else { return }
        print(encode([
            "stage": "observed_key", "key_class": kind, "event_type": type.rawValue,
            "flags": event.flags.rawValue, "source_pid": event.getIntegerValueField(.eventSourceUnixProcessID),
            "source_state": event.getIntegerValueField(.eventSourceStateID),
            "utc_ms": Int64(Date().timeIntervalSince1970 * 1000), "monotonic_ns": DispatchTime.now().uptimeNanoseconds
        ]))
        fflush(stdout)
    }
}

private final class ModifierObserver { var tap: CFMachPort? }
private func modifierDiagnosticCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let info, let tap = Unmanaged<ModifierObserver>.fromOpaque(info).takeUnretainedValue().tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    } else { ModifierDiagnostics.record(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}
