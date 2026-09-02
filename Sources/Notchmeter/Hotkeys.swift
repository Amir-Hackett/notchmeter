import AppKit
import Carbon.HIToolbox

/// Global shortcuts through Carbon's RegisterEventHotKey, which needs no Accessibility permission and works from
/// an accessory app. One handler is installed once; each registered key carries an id that maps to its action.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x4E4D_4854  // "NMHT"

    private init() {}

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            Task { @MainActor in HotkeyCenter.shared.fire(key) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ id: UInt32) {
        actions[id]?()
        Oracle.shared.emit("hotkey", ["id": Int(id)])
    }

    /// Registers the key; returns an id to unregister with, or nil when the system refused it.
    @discardableResult
    func register(_ hotkey: Hotkey, action: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return nil }
        references[id] = reference
        actions[id] = action
        return id
    }

    func unregister(_ id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        actions[id] = nil
    }

    func unregisterAll() {
        for id in Array(references.keys) { unregister(id) }
    }
}

extension Hotkey {
    /// From an NSEvent the recorder saw: the Carbon key code and the Carbon modifier bits of the flags that matter.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !flags.isEmpty || (event.keyCode >= 96 && event.keyCode <= 122) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= Hotkey.commandKey }
        if flags.contains(.shift) { modifiers |= Hotkey.shiftKey }
        if flags.contains(.option) { modifiers |= Hotkey.optionKey }
        if flags.contains(.control) { modifiers |= Hotkey.controlKey }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }
}
