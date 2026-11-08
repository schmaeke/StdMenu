import Carbon

/// A global key combination written as `cmd-shift-space`: modifiers, then a key name or character.
/// Only the function keys may go without a modifier, so that a hotkey never swallows typing.
struct Hotkey: Hashable {
    let code: UInt32
    let modifiers: UInt32

    init?(_ spec: String) {
        var parts = spec.lowercased().split(separator: "-").map(String.init)
        guard let key = parts.popLast(), let code = Keyboard.code(for: key) else { return nil }
        var modifiers = 0
        for part in parts {
            switch part {
            case "cmd", "command": modifiers |= cmdKey
            case "ctrl", "control": modifiers |= controlKey
            case "alt", "opt", "option": modifiers |= optionKey
            case "shift": modifiers |= shiftKey
            default: return nil
            }
        }
        guard modifiers != 0 || Keyboard.functionKeys.contains(Int(code)) else { return nil }
        self.code = code
        self.modifiers = UInt32(modifiers)
    }
}

/// Registers global hotkeys through Carbon, which needs no special permissions.
@MainActor enum Hotkeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static let handler: Void = {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            guard let event, GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr
            else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Hotkeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }()

    /// Registers a hotkey; fails if another application or the system has taken the combination.
    static func add(_ hotkey: Hotkey, action: @escaping () -> Void) -> Bool {
        _ = handler
        let id = UInt32(refs.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.code, hotkey.modifiers, EventHotKeyID(signature: 0x5354_4D4E, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        actions[id] = action
        return true
    }

    static func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }
}

enum Keyboard {
    private static let named = [
        "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
        "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]
    static let functionKeys: Set = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]

    /// The virtual key code for a key name, or for a character on the current keyboard layout,
    /// so that `cmd-z` means the key labelled Z on QWERTZ as well as on QWERTY.
    static func code(for name: String) -> UInt32? {
        if let code = named[name] { return UInt32(code) }
        let character = ["minus": "-", "equal": "="][name] ?? name  // both delimit config lines
        guard character.count == 1,
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue())
        else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            (0..<128).first { code in
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
                return String(utf16CodeUnits: chars, count: length).lowercased() == character
            }.map(UInt32.init)
        }
    }

    /// Sends a key press to the focused application; needs Accessibility access.
    static func press(_ name: String, flags: CGEventFlags) {
        guard let code = code(for: name) else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
