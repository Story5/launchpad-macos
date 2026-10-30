import AppKit

/// LaunchPad 总控：窗口生命周期、打开/关闭编排、搜索、文件夹、键盘路由
@MainActor
final class LaunchPadController: NSViewController {
    private var window: LaunchPadWindow?
    private let backdrop = BackdropView(frame: .zero)
    private let canvas = GridCanvasView(frame: .zero)
    private let searchBar = SearchBarView(frame: .zero)
    private let pageDots = PageIndicatorView(frame: .zero)
    private var folderPanel: FolderPanelView?

    private let library = Library()
    private var metrics = GridMetrics()
    private var didLoadLibrary = false
    private(set) var isPresented = false
    private var searchWorkItem: DispatchWorkItem?

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(backdrop)
        view.addSubview(canvas)
        view.addSubview(searchBar)
        view.addSubview(pageDots)

        canvas.delegate = self
        canvas.library = library
        pageDots.onSelect = { [weak self] index in
            self?.canvas.scrollToPage(index, animated: true)
        }
        searchBar.onTextChange = { [weak self] text in
            self?.scheduleSearch(text)
        }
        searchBar.onCommand = { [weak self] selector in
            self?.handleSearchCommand(selector) ?? false
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        // 切到别的应用（点 Dock 图标、⌘Tab）→ 自动收起，避免全屏窗口挡住别的 App
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(otherApplicationDidActivate(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
        // 兜底：本 App 失去焦点也收起（目标 App 已是前台时不会发激活通知）
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidResignActive),
                                               name: NSApplication.didResignActiveNotification,
                                               object: nil)
    }

    /// 别的 App 被激活时收起启动台（与原生 Launchpad 一致）
    @objc private func otherApplicationDidActivate(_ note: Notification) {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        guard front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        dismissIfPresented()
    }

    @objc private func applicationDidResignActive() {
        dismissIfPresented()
    }

    private func dismissIfPresented() {
        guard isPresented else { return }
        dismiss()
    }

    // MARK: - 布局

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        backdrop.frame = bounds
        canvas.frame = bounds
        searchBar.frame = NSRect(x: (bounds.width - 340) / 2,
                                 y: bounds.height - 88,
                                 width: 340,
                                 height: 30)
        pageDots.frame = NSRect(x: (bounds.width - 460) / 2, y: 58, width: 460, height: 22)
        folderPanel?.frame = bounds
    }

    // MARK: - 显示 / 隐藏

    func toggle() {
        isPresented ? dismiss() : present()
    }

    func present() {
        guard !isPresented else { return }
        let screen = Self.screenContainingCursor() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let window = ensureWindow(for: screen)
        let scale = window.backingScaleFactor
        metrics = GridMetrics.make(viewSize: screen.frame.size)
        backdrop.prepare(screen: screen)
        searchBar.clear()
        window.setFrame(screen.frame, display: true)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        viewDidLayout()

        Task { [weak self] in
            guard let self else { return }
            if !self.didLoadLibrary {
                await self.library.reload(metrics: self.metrics)
                self.didLoadLibrary = true
            } else {
                self.library.metrics = self.metrics
            }
            self.canvas.configure(pages: self.library.pages, metrics: self.metrics, contentsScale: scale)
            self.pageDots.set(pageCount: self.library.pages.count, current: 0)
            self.showChrome(window: window)

            if CommandLine.arguments.contains("--diag") {
                print("[LP] screen=\(screen.frame) scale=\(scale) metrics=\(self.metrics.columns)x\(self.metrics.rows) cap=\(self.metrics.capacity) hotkey=\(HotKeyCenter.shared.hotKeyDescription)")
                self.canvas.debugDump()
            }
            if CommandLine.arguments.contains("--bench") {
                self.canvas.debugBenchmark()
            }
            if CommandLine.arguments.contains("--folder-demo") {
                self.debugPrepareFolderDemo()
            }
            if CommandLine.arguments.contains("--search-demo") {
                self.searchBar.text = "co"
            }
        }
    }

    private func showChrome(window: LaunchPadWindow) {
        isPresented = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        backdrop.setPresented(true, animated: true)
        canvas.animateIn()
        searchBar.setPresented(true, animated: true)
        pageDots.setPresented(true, animated: true)
        searchBar.makeFocused()
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        closeFolder(animated: false)
        searchBar.clear()
        canvas.clearSelection()
        window?.makeFirstResponder(nil)

        canvas.animateOut { [weak self] in
            self?.window?.orderOut(nil)
            // 只有自己还是前台时才让位；被别的 App 顶掉时不要再去动焦点
            if NSApp.isActive { NSApp.deactivate() }
        }
        backdrop.setPresented(false, animated: true)
        searchBar.setPresented(false, animated: true)
        pageDots.setPresented(false, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.isPresented else { return }
            self.canvas.setDisplayPages(self.library.pages, animated: false)
            self.pageDots.set(pageCount: self.library.pages.count, current: 0)
        }
    }

    // MARK: - 调试钩子

    func debugPrepareFolderDemo() {
        guard folderPanel == nil else { return }
        let candidates = library.pages.first?.filter { !$0.isFolder } ?? []
        guard candidates.count >= 6 else { return }
        let items = Array(candidates.prefix(6))
        let folder = library.createFolder(with: items, at: 0, slot: 0)
        canvas.setDisplayPages(library.pages, animated: false)
        if let frame = canvas.frameInWindow(for: folder) {
            openFolder(folder, frame: frame)
        }
    }

    func rescan() {
        let screen = window?.screen ?? NSScreen.main
        guard let screen else { return }
        metrics = GridMetrics.make(viewSize: screen.frame.size)
        Task { [weak self] in
            guard let self else { return }
            await self.library.reload(metrics: self.metrics)
            self.canvas.configure(pages: self.library.pages,
                                  metrics: self.metrics,
                                  contentsScale: self.window?.backingScaleFactor ?? 2)
            self.pageDots.set(pageCount: self.library.pages.count, current: 0)
        }
    }

    private func ensureWindow(for screen: NSScreen) -> LaunchPadWindow {
        if let window, window.screen === screen { return window }
        window?.orderOut(nil)
        let newWindow = LaunchPadWindow(screen: screen)
        newWindow.contentViewController = self
        window = newWindow
        return newWindow
    }

    private static func screenContainingCursor() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    @objc private func screenParametersChanged() {
        guard isPresented, let screen = window?.screen ?? NSScreen.main else { return }
        metrics = GridMetrics.make(viewSize: screen.frame.size)
        library.metrics = metrics
        canvas.update(metrics: metrics, contentsScale: window?.backingScaleFactor ?? 2)
    }

    // MARK: - 搜索

    private func scheduleSearch(_ text: String) {
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applySearch(text) }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    private func applySearch(_ text: String) {
        guard isPresented else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            canvas.setDisplayPages(library.pages, animated: true)
            pageDots.set(pageCount: library.pages.count, current: canvas.pageIndex)
            return
        }
        let matches = library.allTopLevelItems().filter { $0.matches(query: query) }
        if CommandLine.arguments.contains("--diag") {
            print("[LP] search query=\"\(query)\" total=\(library.allTopLevelItems().count) matched=\(matches.count)")
        }
        let capacity = max(1, metrics.capacity)
        var pages: [[LaunchItem]] = []
        var index = 0
        while index < matches.count {
            let end = min(index + capacity, matches.count)
            pages.append(Array(matches[index..<end]))
            index = end
        }
        canvas.setDisplayPages(pages.isEmpty ? [[]] : pages, animated: true)
        pageDots.set(pageCount: max(1, pages.count), current: 0)
    }

    private func handleSearchCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if folderPanel != nil { closeFolder(); return true }
            if searchBar.isSearching {
                searchBar.clear()
                applySearch("")
                return true
            }
            dismiss()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let first = currentSearchResultItem() {
                open(first)
            } else {
                canvas.activateSelection()
            }
            return true
        case #selector(NSResponder.moveLeft(_:)):
            canvas.moveSelection(dx: -1, dy: 0)
            return true
        case #selector(NSResponder.moveRight(_:)):
            canvas.moveSelection(dx: 1, dy: 0)
            return true
        case #selector(NSResponder.moveUp(_:)):
            canvas.moveSelection(dx: 0, dy: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            canvas.moveSelection(dx: 0, dy: 1)
            return true
        default:
            return false
        }
    }

    private func currentSearchResultItem() -> LaunchItem? {
        guard searchBar.isSearching else { return nil }
        let query = searchBar.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.allTopLevelItems().first { $0.matches(query: query) }
    }

    // MARK: - 打开应用 / 文件夹

    private func open(_ item: LaunchItem) {
        if item.isFolder {
            guard let frame = canvas.frameInWindow(for: item) else { return }
            openFolder(item, frame: frame)
            return
        }
        guard let path = item.bundlePath else { return }
        canvas.animateLaunch(for: item)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.dismiss()
        }
    }

    private func openFolder(_ item: LaunchItem, frame: CGRect) {
        guard folderPanel == nil else { return }
        let panel = FolderPanelView(frame: view.bounds)
        panel.delegate = self
        view.addSubview(panel)
        folderPanel = panel
        panel.open(folder: item, originFrame: frame, contentsScale: window?.backingScaleFactor ?? 2)
        canvas.setFolderMode(true)
        backdrop.setFolderMode(true)
        searchBar.setDimmed(true)
        pageDots.setDimmed(true)
    }

    private func closeFolder(animated: Bool = true) {
        guard let panel = folderPanel else { return }
        folderPanel = nil
        canvas.setFolderMode(false, animated: animated)
        backdrop.setFolderMode(false, animated: animated)
        searchBar.setDimmed(false)
        pageDots.setDimmed(false)
        panel.close { [weak self] in
            guard let self else { return }
            self.canvas.setDisplayPages(self.library.pages, animated: false)
            self.pageDots.set(pageCount: self.library.pages.count, current: 0)
        }
    }
}

// MARK: - GridCanvasDelegate

extension LaunchPadController: GridCanvasDelegate {
    func gridCanvasDidChangePage(_ canvas: GridCanvasView) {
        pageDots.set(pageCount: canvas.pageCount, current: canvas.pageIndex)
    }

    func gridCanvasDidClickBackground(_ canvas: GridCanvasView) {
        if folderPanel != nil { closeFolder(); return }
        dismiss()
    }

    func gridCanvas(_ canvas: GridCanvasView, didRequestOpen item: LaunchItem) {
        open(item)
    }

    func gridCanvas(_ canvas: GridCanvasView, didRequestOpenFolder item: LaunchItem, frame: CGRect) {
        openFolder(item, frame: frame)
    }

    func gridCanvasDidMutateLayout(_ canvas: GridCanvasView) {
        canvas.setDisplayPages(library.pages, animated: false)
        pageDots.set(pageCount: library.pages.count, current: canvas.pageIndex)
        for item in library.allTopLevelItems() where item.isFolder {
            canvas.refreshIcon(for: item)
        }
    }
}

// MARK: - FolderPanelDelegate

extension LaunchPadController: FolderPanelDelegate {
    func folderPanel(_ panel: FolderPanelView, didRequestOpen item: LaunchItem) {
        if item.isFolder { return }
        open(item)
    }

    func folderPanelDidClose(_ panel: FolderPanelView) {
        closeFolder()
    }

    func folderPanelDidChangeContent(_ panel: FolderPanelView) {
        library.save()
        canvas.setDisplayPages(library.pages, animated: false)
        // 改名后必须显式刷新网格上的标签：图层是复用的，setDisplayPages 不会重画已有标题
        if let folder = panel.currentFolder { canvas.refreshName(for: folder) }
    }
}
