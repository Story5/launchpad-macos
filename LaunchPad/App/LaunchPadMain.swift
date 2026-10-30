import AppKit

@main
enum LaunchPadMain {
    static func main() {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--slowmo") {
            LPAnimation.timeScale = 4
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 普通 App：Dock 常驻图标（不要改成 .accessory，否则 Dock 里看不到）
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = LaunchPadController()
    private let cmd: NSEvent.ModifierFlags = .command

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyCenter.shared.onHotKey = { [weak self] in
            self?.controller.toggle()
        }
        HotKeyCenter.shared.register()
        setupMainMenu()
        if CommandLine.arguments.contains("--diag") { Self.dumpMainMenu() }

        // 打开 App 即展开启动台（延迟一点等图标缓存就绪）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.controller.present()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点击 Dock 图标（App 已在运行、界面已收起时）→ 重新展开
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !controller.isPresented else { return true }
        controller.present()
        return false
    }

    // MARK: - 主菜单

    private func setupMainMenu() {
        let main = NSMenu()
        main.addItem(applicationMenu())
        main.addItem(editMenu())
        main.addItem(windowMenu())
        NSApp.mainMenu = main
    }

    /// 应用菜单（LaunchPad）：关于 / 重新扫描 / 服务 / 隐藏 / 退出
    private func applicationMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "LaunchPad", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "LaunchPad")
        menu.addItem(actionItem("关于 LaunchPad", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(actionItem("重新扫描应用", #selector(rescanApps(_:)), "r", cmd))
        menu.addItem(.separator())

        let services = NSMenu(title: "服务")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())

        menu.addItem(actionItem("隐藏 LaunchPad", #selector(NSApplication.hide(_:)), "h", cmd))
        menu.addItem(actionItem("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [cmd, .option]))
        menu.addItem(actionItem("全部显示", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(actionItem("退出 LaunchPad", #selector(NSApplication.terminate(_:)), "q", cmd))
        root.submenu = menu
        return root
    }

    /// 编辑菜单：保证搜索框里 ⌘Z / ⌘C / ⌘V 等标准快捷键有对应的菜单项
    private func editMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "编辑")
        menu.addItem(actionItem("撤销", NSSelectorFromString("undo:"), "z", cmd))
        menu.addItem(actionItem("重做", NSSelectorFromString("redo:"), "z", [cmd, .shift]))
        menu.addItem(.separator())
        // cut/copy/paste 定义在 NSStandardKeyBindingResponding（由 NSTextView 实现），没有 Swift 方法可直接 #selector
        menu.addItem(actionItem("剪切", NSSelectorFromString("cut:"), "x", cmd))
        menu.addItem(actionItem("复制", NSSelectorFromString("copy:"), "c", cmd))
        menu.addItem(actionItem("粘贴", NSSelectorFromString("paste:"), "v", cmd))
        menu.addItem(.separator())
        menu.addItem(actionItem("全选", #selector(NSResponder.selectAll(_:)), "a", cmd))
        root.submenu = menu
        return root
    }

    /// 窗口菜单：显示 / 关闭启动台
    private func windowMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "窗口")
        menu.addItem(actionItem("显示启动台", #selector(showLaunchPad(_:)), Self.f4Key))
        menu.addItem(actionItem("关闭启动台", #selector(dismissLaunchPad(_:))))
        menu.addItem(.separator())
        menu.addItem(actionItem("前置全部窗口", #selector(NSApplication.arrangeInFront(_:))))
        root.submenu = menu
        return root
    }

    /// --diag 时打印主菜单结构，便于确认菜单真的建好了
    private static func dumpMainMenu() {
        guard let main = NSApp.mainMenu else { print("diag: mainMenu = nil"); return }
        for item in main.items {
            let names = item.submenu?.items.map { $0.title.isEmpty ? "—" : $0.title } ?? []
            print("diag: menu [\(item.title)] : \(names.joined(separator: " | "))")
        }
    }

    /// 菜单项工厂：自定义 action 一律把 target 指向 AppDelegate，不依赖 responder chain
    private func actionItem(_ title: String,
                            _ action: Selector?,
                            _ key: String = "",
                            _ mask: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = mask }
        return item
    }

    /// F4（与全局热键一致），用功能键字符让菜单栏显示成 F4
    private static let f4Key: String = {
        guard let scalar = Unicode.Scalar(UInt32(Int(NSF4FunctionKey))) else { return "" }
        return String(scalar)
    }()

    // MARK: - 菜单动作

    @objc private func showLaunchPad(_ sender: Any?) {
        controller.present()
    }

    @objc private func dismissLaunchPad(_ sender: Any?) {
        controller.dismiss()
    }

    @objc private func rescanApps(_ sender: Any?) {
        controller.rescan()
    }
}
