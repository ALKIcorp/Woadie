import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, stored as Carbon values so it can be registered
/// directly with `RegisterEventHotKey`.
struct HotKeyShortcut: Codable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// ⌥⎋: speak the selection, or stop if already speaking.
    static let defaultSpeak = HotKeyShortcut(keyCode: UInt32(kVK_Escape), carbonModifiers: UInt32(optionKey))
    /// ⌥⇧⎋: pause or resume.
    static let defaultPause = HotKeyShortcut(keyCode: UInt32(kVK_Escape), carbonModifiers: UInt32(optionKey | shiftKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Builds a shortcut from a key-down event, or nil when the event has no
    /// ⌘, ⌥ or ⌃ (a bare key or ⇧-only combo would swallow normal typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
    }

    var displayString: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Escape: return "⎋"
        case kVK_Return: return "↩"
        case kVK_Space: return "Space"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_F1...kVK_F20 where functionKeyNumber(keyCode) != nil:
            return "F\(functionKeyNumber(keyCode)!)"
        default:
            return characterName(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    private static func functionKeyNumber(_ keyCode: UInt32) -> Int? {
        let keys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return keys.firstIndex(of: Int(keyCode)).map { $0 + 1 }
    }

    /// The character the key types on the current keyboard layout.
    private static func characterName(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

enum GlobalHotKeyAction: UInt32, CaseIterable {
    case speakOrStop = 1
    case pauseOrResume = 2

    var defaultsKey: String {
        switch self {
        case .speakOrStop: return "hotKey.speakOrStop"
        case .pauseOrResume: return "hotKey.pauseOrResume"
        }
    }

    var defaultShortcut: HotKeyShortcut {
        switch self {
        case .speakOrStop: return .defaultSpeak
        case .pauseOrResume: return .defaultPause
        }
    }
}

/// System-wide shortcuts through Carbon's `RegisterEventHotKey`. Unlike an
/// `NSEvent` global monitor it needs no Input Monitoring permission, and the
/// key press is consumed instead of also reaching the frontmost app.
@MainActor
final class GlobalHotKeyService {
    static let shared = GlobalHotKeyService()

    private var handlers: [GlobalHotKeyAction: () -> Void] = [:]
    private var registered: [GlobalHotKeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let defaults: UserDefaults
    private static let signature: OSType = 0x574F_4144 // "WOAD"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shortcut(for action: GlobalHotKeyAction) -> HotKeyShortcut? {
        guard let data = defaults.data(forKey: action.defaultsKey) else { return action.defaultShortcut }
        // An empty value means the user cleared the shortcut.
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(HotKeyShortcut.self, from: data)) ?? action.defaultShortcut
    }

    /// Saves and re-registers a shortcut; nil turns the action's shortcut off.
    /// Returns false when macOS refuses it (for example the other action
    /// already uses the same keys).
    @discardableResult
    func setShortcut(_ shortcut: HotKeyShortcut?, for action: GlobalHotKeyAction) -> Bool {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: action.defaultsKey)
        } else {
            defaults.set(Data(), forKey: action.defaultsKey)
        }
        return register(action)
    }

    func start(handlers: [GlobalHotKeyAction: () -> Void]) {
        self.handlers = handlers
        installEventHandlerIfNeeded()
        for action in GlobalHotKeyAction.allCases {
            register(action)
        }
    }

    @discardableResult
    private func register(_ action: GlobalHotKeyAction) -> Bool {
        if let ref = registered.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
        guard let shortcut = shortcut(for: action) else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: action.rawValue),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        registered[action] = ref
        return true
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKeyService.signature,
                  let action = GlobalHotKeyAction(rawValue: hotKeyID.id)
            else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<GlobalHotKeyService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                service.handlers[action]?()
            }
            return noErr
        }, 1, &spec, context, &eventHandler)
    }
}
