import Carbon
import Foundation

/// Carbon only delivers registered combinations; no keyboard stream is observed.
@MainActor
final class MacGlobalHotkeys {
    private var handler: EventHandlerRef?
    private var installationStatus: OSStatus = noErr
    private var registrations: [EventHotKeyRef] = []
    var action: ((UInt32, Bool) -> Void)?

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        installationStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, ByteCount(MemoryLayout<EventHotKeyID>.size), nil, &key)
            guard status == noErr else { return status }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let owner = Unmanaged<MacGlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.action?(key.id, pressed) }
            return noErr
        }, ItemCount(types.count), &types, context, &handler)
    }

    func configure(summon: String?, pushToTalk: String?) throws {
        guard installationStatus == noErr else {
            throw HotkeyError.invalid("Cannot install Carbon hotkey handler: OSStatus \(installationStatus).")
        }
        unregister()
        do {
            if let summon { try register(summon, id: 1) }
            if let pushToTalk {
                guard summon?.lowercased() != pushToTalk.lowercased() else {
                    throw HotkeyError.invalid("Summon and push-to-talk must use different combinations.")
                }
                try register(pushToTalk, id: 2)
            }
        } catch {
            unregister()
            throw error
        }
    }

    func unregister() {
        registrations.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
    }

    private func register(_ shortcut: String, id: UInt32) throws {
        let parsed = try Self.parse(shortcut)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.0, parsed.1, EventHotKeyID(signature: 0x4c424f54, id: id), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            throw HotkeyError.invalid("Cannot register \(shortcut): Carbon OSStatus \(status). Another application may own this shortcut.")
        }
        registrations.append(reference)
    }

    static func parse(_ shortcut: String) throws -> (UInt32, UInt32) {
        let parts = shortcut.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, parts.count > 1 else {
            throw HotkeyError.invalid("Use a modified key such as control+option+space; blank disables the shortcut.")
        }
        let modifiers: [String: UInt32] = ["command": UInt32(cmdKey), "control": UInt32(controlKey), "option": UInt32(optionKey), "shift": UInt32(shiftKey)]
        var flags: UInt32 = 0
        for part in parts.dropLast() {
            guard let modifier = modifiers[part], flags & modifier == 0 else {
                throw HotkeyError.invalid("Unknown or repeated modifier: \(part).")
            }
            flags |= modifier
        }
        guard flags & (UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)) != 0 else {
            throw HotkeyError.invalid("A global shortcut needs Command, Control, or Option.")
        }
        let keys: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "return": 36, "tab": 48, "space": 49, "escape": 53,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
            "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
        ]
        guard let code = keys[key] else { throw HotkeyError.invalid("Unsupported shortcut key: \(key).") }
        return (code, flags)
    }
}

enum HotkeyError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
