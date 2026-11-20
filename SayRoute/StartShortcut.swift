import AppKit
import Carbon

/// Store the physical key code so a change of input method cannot change which key starts dictation.
struct StartShortcut: Equatable {
    static let primaryModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    private static let fallbackLabels: [Int64: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 44: "/", 45: "N", 46: "M",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 47: ".", 50: "`"
    ]
    static let standard = StartShortcut(keyCode: 44, modifiers: .maskControl)!
    let keyCode: Int64
    let modifiers: CGEventFlags

    init?(keyCode: Int64, modifiers: CGEventFlags) {
        guard Self.fallbackLabels[keyCode] != nil,
              !Self.isPasteShortcut(keyCode: keyCode, modifiers: modifiers),
              !modifiers.intersection([.maskControl, .maskCommand, .maskAlternate]).isEmpty,
              modifiers.subtracting(Self.primaryModifiers).isEmpty else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static func isPasteShortcut(keyCode: Int64, modifiers: CGEventFlags) -> Bool {
        keyCode == 9 && modifiers.intersection(primaryModifiers) == .maskCommand
    }

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && !flags.contains(.maskSecondaryFn)
            && flags.intersection(Self.primaryModifiers) == modifiers
    }

    var title: String {
        var names = [String]()
        if modifiers.contains(.maskControl) { names.append("Control") }
        if modifiers.contains(.maskAlternate) { names.append("Option") }
        if modifiers.contains(.maskShift) { names.append("Shift") }
        if modifiers.contains(.maskCommand) { names.append("Command") }
        names.append(layoutLabel ?? Self.fallbackLabels[keyCode]!)
        return names.joined(separator: " + ")
    }

    private var layoutLabel: String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let result = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKey, characters.count, &length, &characters)
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

struct StartShortcutPreferences {
    static let key = "dictationStartShortcut"
    let defaults: UserDefaults

    var shortcut: StartShortcut {
        get {
            guard let values = defaults.dictionary(forKey: Self.key),
                  let keyCode = values["keyCode"] as? Int64,
                  let flags = values["modifiers"] as? UInt64,
                  let shortcut = StartShortcut(keyCode: keyCode, modifiers: CGEventFlags(rawValue: flags))
            else { return .standard }
            return shortcut
        }
        nonmutating set {
            if newValue == .standard {
                defaults.removeObject(forKey: Self.key)
            } else {
                defaults.set(["keyCode": NSNumber(value: newValue.keyCode),
                              "modifiers": NSNumber(value: newValue.modifiers.rawValue)], forKey: Self.key)
            }
        }
    }
}

enum ShortcutInteraction: Equatable {
    case idle, record, test

    enum Result: Equatable {
        case pass, cancel, invalid, pasteReserved, save(StartShortcut), testPassed, testMiss
    }

    func keyDown(keyCode: Int64, flags: CGEventFlags, current: StartShortcut) -> Result {
        guard self != .idle else { return .pass }
        if keyCode == 53 { return .cancel }
        if self == .test { return current.matches(keyCode: keyCode, flags: flags) ? .testPassed : .testMiss }
        if StartShortcut.isPasteShortcut(keyCode: keyCode, modifiers: flags) { return .pasteReserved }
        guard !flags.contains(.maskSecondaryFn),
              let shortcut = StartShortcut(keyCode: keyCode, modifiers: flags.intersection(StartShortcut.primaryModifiers))
        else { return .invalid }
        return .save(shortcut)
    }
}
