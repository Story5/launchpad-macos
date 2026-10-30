import AppKit
import Carbon.HIToolbox

/// 全局热键（默认 F4，与原生 LaunchPad 一致；注册失败自动降级为 ⌥Space）
final class HotKeyCenter: @unchecked Sendable {
    static let shared = HotKeyCenter()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var registeredKeyCode: UInt32 = 0
    private var registeredModifiers: UInt32 = 0

    var onHotKey: (() -> Void)?

    private let signature: OSType = 0x4C505244 // "LPRD"

    func register() {
        installHandler()
        if registerKey(keyCode: UInt32(kVK_F4), modifiers: 0) { return }
        _ = registerKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    }

    @discardableResult
    private func registerKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, identifier, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            registeredKeyCode = keyCode
            registeredModifiers = modifiers
            return true
        }
        return false
    }

    private func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(),
                            hotKeyEventHandler,
                            1,
                            &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandler)
    }

    fileprivate func handleHotKey() {
        DispatchQueue.main.async { self.onHotKey?() }
    }

    var hotKeyDescription: String {
        if registeredKeyCode == UInt32(kVK_F4) { return "F4" }
        if registeredKeyCode == UInt32(kVK_Space) { return "⌥Space" }
        return "未注册"
    }
}

private func hotKeyEventHandler(_ nextHandler: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &identifier)
    if status == noErr {
        let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
        center.handleHotKey()
    }
    return noErr
}
