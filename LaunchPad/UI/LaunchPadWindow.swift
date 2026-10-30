import AppKit

/// 全屏无边框窗口：出现在所有 Space，层级低于 Dock（与原生 LaunchPad 一致）
final class LaunchPadWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        titlebarAppearsTransparent = true
    }

    /// 原生 LaunchPad 按 Esc / 点空白处关闭
    override func cancelOperation(_ sender: Any?) {
        (contentViewController as? LaunchPadController)?.dismiss()
    }
}
