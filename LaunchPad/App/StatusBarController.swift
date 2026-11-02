import AppKit

/// 菜单栏图标（状态栏常驻）：
/// - 左键单击：显示 / 关闭启动台（这是这个图标的主要用途）
/// - 右键单击：弹出菜单（重新扫描、隐藏图标、退出等）
/// 图标是代码画的矢量模板图（3×3 网格，和 AppIcon 的九宫格语义一致），
/// 深浅色菜单栏下会自动反色，不需要额外的图片资源。
@MainActor
final class StatusBarController {
    private static let visibilityKey = "LaunchPadMenuBarIconVisible"

    private var item: NSStatusItem?
    private weak var controller: LaunchPadController?
    /// 右键菜单：建一次就复用（自定义 action 的 target 指向 self，NSApp 的 action 留空走响应链）
    private lazy var contextMenu: NSMenu = buildMenu()

    /// 可见性变化回调（用来同步主菜单里那个开关的状态）
    var onVisibilityChange: ((Bool) -> Void)?

    init(controller: LaunchPadController) {
        self.controller = controller
    }

    var isVisible: Bool {
        UserDefaults.standard.object(forKey: Self.visibilityKey) as? Bool ?? true
    }

    func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: Self.visibilityKey)
        visible ? show() : hide()
        onVisibilityChange?(visible)
    }

    /// 按上次的偏好决定要不要显示（首次运行默认显示）
    func install() {
        if isVisible { show() }
    }

    private func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Self.icon()
        image.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "LaunchPad"
        // 不用 item.menu —— 那样任何点击都只会弹菜单。改成自己接住左右键：
        // 左键直接开关启动台，右键才弹菜单。
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
    }

    private func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    @objc private func handleClick(_ sender: Any?) {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            controller?.toggle()
            return
        }
        showContextMenu()
    }

    /// 弹出右键菜单：临时把菜单挂到状态项上再模拟点一次，是 NSStatusItem 唯一稳定的弹菜单方式
    private func showContextMenu() {
        guard let item, let button = item.button else { return }
        item.menu = contextMenu
        button.performClick(nil)
        item.menu = nil
    }

    /// --diag 用：把菜单栏菜单的结构打出来，确认每个菜单项都真的建好了、并且是可用状态
    func dumpMenu() {
        contextMenu.update()
        let names = contextMenu.items.map { item -> String in
            if item.isSeparatorItem { return "—" }
            return item.isEnabled ? item.title : "\(item.title)(禁用)"
        }
        print("diag: statusMenu : \(names.joined(separator: " | "))")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "LaunchPad")
        menu.addItem(item("显示启动台", #selector(showLaunchPad(_:))))
        menu.addItem(item("关闭启动台", #selector(dismissLaunchPad(_:))))
        menu.addItem(.separator())
        menu.addItem(item("重新扫描应用", #selector(rescanApps(_:)), "r", .command))
        menu.addItem(.separator())
        menu.addItem(item("隐藏菜单栏图标", #selector(hideIcon(_:))))
        menu.addItem(.separator())
        // 这两个是 NSApplication 的方法，target 必须留空交给响应链 ——
        // 指到 self 的话菜单项会因为「target 不响应 action」被直接置灰
        menu.addItem(item("关于 LaunchPad",
                          #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                          ownedBySelf: false))
        menu.addItem(item("退出 LaunchPad", #selector(NSApplication.terminate(_:)), "q", .command,
                          ownedBySelf: false))
        return menu
    }

    private func item(_ title: String,
                      _ action: Selector,
                      _ key: String = "",
                      _ mask: NSEvent.ModifierFlags = [],
                      ownedBySelf: Bool = true) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        // 只有本类自己实现的 action 才把 target 指过来；NSApp 的 action 必须留空走响应链
        if ownedBySelf { menuItem.target = self }
        if !key.isEmpty { menuItem.keyEquivalentModifierMask = mask }
        return menuItem
    }

    // MARK: 菜单动作

    @objc private func showLaunchPad(_ sender: Any?) { controller?.present() }
    @objc private func dismissLaunchPad(_ sender: Any?) { controller?.dismiss() }
    @objc private func rescanApps(_ sender: Any?) { controller?.rescan() }
    @objc private func hideIcon(_ sender: Any?) { setVisible(false) }
}

// MARK: - 图标

extension StatusBarController {
    /// 3×3 圆角方块网格：矢量绘制，任意分辨率都清晰
    static func icon() -> NSImage {
        let side: CGFloat = 18
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let gap: CGFloat = 1.7
            let cell = (side - gap * 2) / 3
            let radius = cell * 0.30
            // 模板图只看 alpha，颜色会被系统换成菜单栏的前景色
            NSColor.black.setFill()
            for row in 0..<3 {
                for col in 0..<3 {
                    let x = CGFloat(col) * (cell + gap)
                    let y = CGFloat(row) * (cell + gap)
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: cell, height: cell),
                                 xRadius: radius, yRadius: radius).fill()
                }
            }
            return true
        }
    }
}
