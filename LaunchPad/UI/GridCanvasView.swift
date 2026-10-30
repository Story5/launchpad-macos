import AppKit
import QuartzCore

@MainActor protocol GridCanvasDelegate: AnyObject {
    func gridCanvasDidChangePage(_ canvas: GridCanvasView)
    func gridCanvasDidClickBackground(_ canvas: GridCanvasView)
    func gridCanvas(_ canvas: GridCanvasView, didRequestOpen item: LaunchItem)
    func gridCanvas(_ canvas: GridCanvasView, didRequestOpenFolder item: LaunchItem, frame: CGRect)
    func gridCanvasDidMutateLayout(_ canvas: GridCanvasView)
}

/// LaunchPad 网格画布：一个 NSView 承载全部图标图层。
/// · 只实例化「当前页 ±1」的图层（虚拟化）
/// · 滚动/吸附由自研弹簧 + CVDisplayLink 驱动，逐帧只改一个 transform
/// · 位置重排用 CASpringAnimation 跑在 render server
@MainActor
final class GridCanvasView: NSView {
    weak var delegate: GridCanvasDelegate?
    weak var library: Library?

    private let zoomLayer = CALayer()
    private let scrollLayer = CALayer()
    private let overlayLayer = CALayer()
    private var iconLayers: [ObjectIdentifier: IconLayer] = [:]
    private var layerPool: [IconLayer] = []

    private var displayPages: [[LaunchItem]] = [[]]
    private var metrics = GridMetrics()
    private var viewSize: CGSize = .zero
    private var contentsScale: CGFloat = 2

    private var scrollSpring = ScalarSpring(value: 0, parameters: LPSpring.paging)
    private let driver = FrameDriver()
    private var currentPage = 0
    private var lastWheelTime: TimeInterval = 0
    private var wheelVelocity: CGFloat = 0

    // 整页翻页手势状态：一次双指手势最多走一页，且必定停在整页边界上
    private var pagingActive = false
    private var pagingStartPage = 0
    private var pagingAccum: CGFloat = 0
    private var pagingSnapWork: DispatchWorkItem?

    private var pageSize: CGFloat { max(1, viewSize.width) }
    private var maxOffset: CGFloat { CGFloat(max(0, displayPages.count - 1)) * pageSize }

    // 拖拽状态
    private var pendingItem: LaunchItem?
    private var pendingLayer: IconLayer?
    private var downPoint: NSPoint = .zero
    private var isDragging = false
    private var dragItem: LaunchItem?
    private var dragLayer: IconLayer?
    private var dragGrabOffset: CGPoint = .zero
    private var gap: (page: Int, slot: Int)?
    private var hoverItem: LaunchItem?      // 悬停在其他图标上（可能新建文件夹）
    private var dwellStart: TimeInterval = 0
    private var dwellPoint: NSPoint = .zero
    private var folderCandidate: LaunchItem?
    private var autoPageWorkItem: DispatchWorkItem?

    // 键盘导航
    private var selection: (page: Int, slot: Int)?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    /// 调试用：LP_TRACE_PAGE=1 时打印翻页轨迹（目标页 / 落位后的 offset 是否整页）
    private static let tracePaging = ProcessInfo.processInfo.environment["LP_TRACE_PAGE"] == "1"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(zoomLayer)
        zoomLayer.addSublayer(scrollLayer)
        layer?.addSublayer(overlayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 配置

    func configure(pages: [[LaunchItem]], metrics: GridMetrics, contentsScale: CGFloat) {
        self.metrics = metrics
        self.contentsScale = contentsScale
        self.viewSize = bounds.size
        setDisplayPages(pages, animated: false)
    }

    func setDisplayPages(_ pages: [[LaunchItem]], animated: Bool) {
        displayPages = pages.isEmpty ? [[]] : pages
        resetPagingGesture()
        currentPage = min(currentPage, max(0, displayPages.count - 1))
        let target = CGFloat(currentPage) * pageSize
        scrollSpring.jump(to: target)
        applyOffset()
        syncLayers(animate: animated)
        delegate?.gridCanvasDidChangePage(self)
    }

    func update(metrics: GridMetrics, contentsScale: CGFloat) {
        self.metrics = metrics
        self.contentsScale = contentsScale
        self.viewSize = bounds.size
        for layer in iconLayers.values {
            if let item = layer.item {
                layer.configure(item: item,
                                cellSize: CGSize(width: metrics.cellWidth, height: metrics.cellHeight),
                                imageSize: metrics.imageSize,
                                contentsScale: contentsScale)
            }
        }
        scrollSpring.jump(to: CGFloat(currentPage) * pageSize)
        applyOffset()
        relayout(animated: false)
    }

    var pageIndex: Int { currentPage }
    var pageCount: Int { displayPages.count }

    override func layout() {
        super.layout()
        viewSize = bounds.size
        zoomLayer.frame = bounds
        overlayLayer.frame = bounds
        scrollLayer.frame = CGRect(x: 0, y: 0, width: pageSize * CGFloat(max(1, displayPages.count)), height: bounds.height)
        scrollSpring.jump(to: CGFloat(currentPage) * pageSize)
        applyOffset()
        relayout(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: - 图层同步（虚拟化）

    private func visiblePageRange() -> Range<Int> {
        guard !displayPages.isEmpty else { return 0..<0 }
        let lower = max(0, currentPage - 1)
        let upper = min(displayPages.count - 1, currentPage + 1)
        return lower..<(upper + 1)
    }

    private func syncLayers(animate: Bool) {
        let range = visiblePageRange()
        var visible = Set<ObjectIdentifier>()
        for page in range where page < displayPages.count {
            for item in displayPages[page] { visible.insert(ObjectIdentifier(item)) }
        }

        // 移除不可见图层（淡出）
        for (key, layer) in iconLayers where !visible.contains(key) {
            iconLayers.removeValue(forKey: key)
            release(layer, animated: animate)
        }

        // 新增 / 更新
        for page in range where page < displayPages.count {
            var slot = 0
            for item in displayPages[page] {
                if let gap, gap.page == page, gap.slot == slot { slot += 1 }
                let layer = acquireLayer(for: item, animate: animate, page: page, slot: slot)
                position(layer, page: page, slot: slot, animate: animate)
                slot += 1
            }
        }
    }

    private func acquireLayer(for item: LaunchItem, animate: Bool, page: Int, slot: Int) -> IconLayer {
        if let existing = iconLayers[ObjectIdentifier(item)] { return existing }
        let layer: IconLayer
        if let reused = layerPool.popLast() {
            layer = reused
        } else {
            layer = IconLayer()
        }
        layer.resetTransientState()
        layer.configure(item: item,
                        cellSize: CGSize(width: metrics.cellWidth, height: metrics.cellHeight),
                        imageSize: metrics.imageSize,
                        contentsScale: contentsScale)
        iconLayers[ObjectIdentifier(item)] = layer
        scrollLayer.addSublayer(layer)
        position(layer, page: page, slot: slot, animate: false)
        loadIcon(for: item, into: layer)
        if animate {
            let col = slot % metrics.columns
            let row = slot / metrics.columns
            layer.animateIn(delay: LPAnimation.rippleDelay(column: col, row: row, columns: metrics.columns, rows: metrics.rows))
        }
        return layer
    }

    private func release(_ layer: IconLayer, animated: Bool) {
        guard layer.superlayer != nil else { return }
        if animated {
            layer.animateOut(delay: 0) { [weak self] in
                layer.removeFromSuperlayer()
                self?.layerPool.append(layer)
            }
        } else {
            layer.removeFromSuperlayer()
            layerPool.append(layer)
        }
    }

    private func loadIcon(for item: LaunchItem, into layer: IconLayer) {
        let pixel = Int(metrics.imageSize * contentsScale)
        let request: IconRequest
        if item.isFolder {
            request = IconRequest(kind: .folder(childPaths: item.childBundlePaths), key: item.iconVersion, pixelSize: pixel)
        } else {
            request = IconRequest(kind: .app(path: item.bundlePath ?? ""), key: item.iconVersion, pixelSize: pixel)
        }
        if let cached = IconStore.shared.cached(request) {
            layer.applyIcon(cached)
            return
        }
        let targetID = ObjectIdentifier(item)
        IconStore.shared.fetch(request) { [weak self, weak layer] image in
            guard let self, let layer, layer.item?.id == item.id,
                  self.iconLayers[targetID] === layer else { return }
            layer.applyIcon(image)
        }
    }

    func refreshIcon(for item: LaunchItem) {
        guard let layer = iconLayers[ObjectIdentifier(item)] else { return }
        loadIcon(for: item, into: layer)
    }

    // MARK: - 布局

    private func frameForItem(page: Int, slot: Int) -> CGRect {
        let origin = metrics.gridOrigin(viewSize: viewSize)
        let col = slot % metrics.columns
        let row = slot / metrics.columns
        let x = CGFloat(page) * pageSize + origin.x + CGFloat(col) * metrics.cellWidth
        let yTop = origin.y + CGFloat(row) * metrics.cellHeight
        let y = viewSize.height - yTop - metrics.cellHeight
        return CGRect(x: x, y: y, width: metrics.cellWidth, height: metrics.cellHeight)
    }

    private func position(_ layer: IconLayer, page: Int, slot: Int, animate: Bool) {
        let frame = frameForItem(page: page, slot: slot)
        let newPosition = CGPoint(x: frame.midX, y: frame.midY)
        if !animate {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = frame
            CATransaction.commit()
            return
        }
        let current = layer.presentation()?.position ?? layer.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        CATransaction.commit()
        if abs(current.x - newPosition.x) > 0.5 || abs(current.y - newPosition.y) > 0.5 {
            layer.add(LPAnimation.pointSpring(params: LPSpring.reflow, from: current, to: newPosition), forKey: "positionSpring")
        }
    }

    private func relayout(animated: Bool) {
        for (key, layer) in iconLayers {
            guard let item = layer.item,
                  let loc = location(of: item) else { continue }
            var slot = loc.slot
            if let gap, gap.page == loc.page, gap.slot <= loc.slot { slot += 1 }
            position(layer, page: loc.page, slot: slot, animate: animated)
            _ = key
        }
    }

    private func location(of item: LaunchItem) -> (page: Int, slot: Int)? {
        for (page, items) in displayPages.enumerated() {
            if let slot = items.firstIndex(where: { $0 === item }) { return (page, slot) }
        }
        return nil
    }

    // MARK: - 滚动

    private func applyOffset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollLayer.transform = CATransform3DMakeTranslation(-scrollSpring.value, 0, 0)
        CATransaction.commit()
    }

    func scrollToPage(_ page: Int, animated: Bool, initialVelocity: CGFloat = 0) {
        let clamped = max(0, min(displayPages.count - 1, page))
        let target = CGFloat(clamped) * pageSize
        currentPage = clamped
        if !animated {
            scrollSpring.jump(to: target)
            applyOffset()
            syncLayers(animate: false)
            delegate?.gridCanvasDidChangePage(self)
            return
        }
        scrollSpring.retarget(target, initialVelocity: initialVelocity)
        syncLayers(animate: false)
        delegate?.gridCanvasDidChangePage(self)
        startScrollAnimation()
    }

    private func startScrollAnimation() {
        guard !driver.isRunning else { return }
        driver.onFrame = { [weak self] dt in self?.stepScroll(dt: CGFloat(dt)) }
        driver.start()
    }

    private func stepScroll(dt: CGFloat) {
        let settled = scrollSpring.step(dt: dt)
        applyOffset()
        if settled {
            driver.stop()
            syncLayers(animate: false)
            if Self.tracePaging {
                let page = scrollSpring.value / pageSize
                print(String(format: "[LP] settled: offset=%.1f page=%.3f %@",
                             scrollSpring.value, page, abs(page - page.rounded()) < 0.001 ? "(整页)" : "(!! 非整页)"))
            }
        }
    }

    private func rubberBand(_ value: CGFloat) -> CGFloat {
        let upper = maxOffset
        if value < 0 { return -Self.resistance(-value) }
        if value > upper { return upper + Self.resistance(value - upper) }
        return value
    }

    private static func resistance(_ d: CGFloat) -> CGFloat {
        let limit: CGFloat = 70
        return (1 - 1 / (d / limit + 1)) * limit
    }

    private func updateCurrentPageFromOffset() {
        let page = Int(round(scrollSpring.value / pageSize))
        let clamped = max(0, min(displayPages.count - 1, page))
        if clamped != currentPage {
            currentPage = clamped
            syncLayers(animate: false)
            delegate?.gridCanvasDidChangePage(self)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isDragging, displayPages.count > 1 else { return }

        // 惯性事件：原生 Launchpad 不做惯性翻页，忽略位移；
        // 但 .ended 仍要用来收尾，保证一定吸附回整页。
        if event.momentumPhase == .ended {
            finishPagingGesture()
            return
        }
        if event.momentumPhase != [] { return }

        // 手指离开 → 收尾翻页。必须放在 delta 守卫之前：
        // 结束那一下的 scrollingDeltaX 通常是 0，若先判 delta 会直接 return，
        // 吸附永远不执行，内容就停在半页位置（正是之前的 bug）。
        if event.phase == .ended || event.phase == .cancelled {
            finishPagingGesture()
            return
        }

        // AppKit 的 scrollingDeltaX 表示「手指移动方向」（已包含系统「自然滚动」偏好）：
        // 双指向左滑 → deltaX < 0。原生 Launchpad 此时翻到下一页，
        // 而 offset 增大 = 内容左移 = 后面的页，所以这里取负号。
        let dx = -event.scrollingDeltaX
        guard abs(dx) > 0.01 else { return }

        let now = event.timestamp
        let dt = max(0.008, min(0.1, now - lastWheelTime))
        lastWheelTime = now
        wheelVelocity = dx / CGFloat(dt)

        if !pagingActive { beginPagingGesture() }
        pagingAccum += dx

        // 跟手，但单次手势最多走一页（与原生一致：一滑 = 一页），超出的部分做橡皮筋
        let base = CGFloat(pagingStartPage) * pageSize
        let raw = base + pagingAccum
        var target = raw
        let oneBefore = base - pageSize
        let oneAfter = base + pageSize
        if target < oneBefore { target = oneBefore - Self.resistance(oneBefore - target) }
        else if target > oneAfter { target = oneAfter + Self.resistance(target - oneAfter) }

        driver.stop()
        scrollSpring.jump(to: rubberBand(target))
        applyOffset()
        updateCurrentPageFromOffset()
        schedulePagingSnapFallback()
    }

    // MARK: 整页翻页

    private func beginPagingGesture() {
        pagingActive = true
        pagingAccum = 0
        pagingStartPage = currentPage
        driver.stop()
    }

    private func resetPagingGesture() {
        pagingActive = false
        pagingAccum = 0
        wheelVelocity = 0
        pagingSnapWork?.cancel()
        pagingSnapWork = nil
    }

    /// 手势结束（或兜底超时）→ 判定翻到哪一页，并且只会是整页。
    private func finishPagingGesture() {
        pagingSnapWork?.cancel()
        pagingSnapWork = nil
        guard pagingActive else { return }
        pagingActive = false

        let velocity = wheelVelocity
        let distance = pagingAccum
        // 走够 15% 页宽就算一次翻页；没走够但甩得够快（>0.6 页宽/秒）也算
        var delta = 0
        if distance > pageSize * 0.15 { delta = 1 }
        else if distance < -pageSize * 0.15 { delta = -1 }
        else if velocity > pageSize * 0.6 { delta = 1 }
        else if velocity < -pageSize * 0.6 { delta = -1 }

        pagingAccum = 0
        wheelVelocity = 0
        let target = max(0, min(displayPages.count - 1, pagingStartPage + delta))
        if Self.tracePaging {
            print(String(format: "[LP] paging end: from=%d -> %d (dist=%.0f vel=%.0f)",
                         pagingStartPage, target, distance, velocity))
        }
        scrollToPage(target, animated: true, initialVelocity: velocity * 0.3)
    }

    /// 兜底：万一收不到手势结束事件（部分鼠标/驱动不传），空闲 0.14s 后强制吸附回整页，
    /// 保证任何情况下都不会停在半页。
    private func schedulePagingSnapFallback() {
        pagingSnapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishPagingGesture() }
        pagingSnapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    // MARK: - 命中测试

    private func slotAt(point: NSPoint) -> (page: Int, slot: Int)? {
        let x = point.x + scrollSpring.value
        let page = Int(floor(x / pageSize))
        guard page >= 0, page < displayPages.count else { return nil }
        let localX = x - CGFloat(page) * pageSize
        let origin = metrics.gridOrigin(viewSize: viewSize)
        let appkitY = viewSize.height - point.y
        let col = Int(floor((localX - origin.x) / metrics.cellWidth))
        let row = Int(floor((appkitY - origin.y) / metrics.cellHeight))
        guard col >= 0, col < metrics.columns, row >= 0, row < metrics.rows else { return nil }
        return (page, row * metrics.columns + col)
    }

    private func itemAt(point: NSPoint) -> (item: LaunchItem, layer: IconLayer)? {
        guard let hit = slotAt(point: point),
              hit.page < displayPages.count,
              hit.slot < displayPages[hit.page].count else { return nil }
        let item = displayPages[hit.page][hit.slot]
        guard let layer = iconLayers[ObjectIdentifier(item)] else { return nil }
        return (item, layer)
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = itemAt(point: point) else {
            delegate?.gridCanvasDidClickBackground(self)
            return
        }
        pendingItem = hit.item
        pendingLayer = hit.layer
        downPoint = point
        hit.layer.setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let item = pendingItem, let layer = pendingLayer else { return }
        if !isDragging {
            let dx = point.x - downPoint.x
            let dy = point.y - downPoint.y
            guard dx * dx + dy * dy > 36 else { return }
            beginDrag(item: item, layer: layer, at: point)
        }
        updateDrag(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isDragging {
            finishDrag(at: point)
            return
        }
        pendingLayer?.setPressed(false)
        if let item = pendingItem {
            delegate?.gridCanvas(self, didRequestOpen: item)
        }
        pendingItem = nil
        pendingLayer = nil
    }

    // MARK: 拖拽

    private func beginDrag(item: LaunchItem, layer: IconLayer, at point: NSPoint) {
        isDragging = true
        dragItem = item
        layer.setPressed(false)

        let drag = IconLayer()
        drag.configure(item: item,
                       cellSize: CGSize(width: metrics.cellWidth, height: metrics.cellHeight),
                       imageSize: metrics.imageSize,
                       contentsScale: contentsScale)
        drag.applyIcon(layer.currentIcon())
        drag.frame = layer.frame
        overlayLayer.addSublayer(drag)
        dragLayer = drag
        dragGrabOffset = CGPoint(x: point.x - layer.frame.midX, y: point.y - layer.frame.midY)

        // 原位置隐藏，并从布局里移除（留出空位）
        if let loc = location(of: item) {
            displayPages[loc.page].remove(at: loc.slot)
        }
        layer.opacity = 0

        drag.add(LPAnimation.spring("transform.scale", params: LPSpring.lift, from: 1.0, to: 1.14), forKey: "lift")
        drag.transform = CATransform3DMakeScale(1.14, 1.14, 1)

        for iconLayer in iconLayers.values where iconLayer !== layer {
            iconLayer.startJiggle()
        }
        moveDragLayer(to: point)
    }

    private func moveDragLayer(to point: NSPoint) {
        guard let drag = dragLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drag.position = CGPoint(x: point.x - dragGrabOffset.x, y: point.y - dragGrabOffset.y)
        CATransaction.commit()
    }

    private func updateDrag(to point: NSPoint) {
        guard isDragging, let item = dragItem else { return }
        moveDragLayer(to: point)

        // 边缘自动翻页
        scheduleAutoPageIfNeeded(at: point)

        guard let hit = slotAt(point: point), hit.page < displayPages.count else { return }

        // 几何格子 → 实际条目下标（要扣掉已打开的空位，否则会命中错位一格）
        if let index = itemIndex(atPage: hit.page, slot: hit.slot) {
            let candidate = displayPages[hit.page][index]
            // sticky：已经锁定的目标用更宽松的判定范围，避免在格子边界反复横跳
            if candidate !== item, isOver(point: point, page: hit.page, slot: hit.slot, sticky: hoverItem === candidate) {
                if hoverItem !== candidate { setHover(candidate, at: point) }
                // 压在图标上时冻结布局：不再开空位。
                // 否则一靠近，空位动画就把目标图标推走，永远对不准（原来的"一直在动"）。
                setGap(nil)
                let now = ProcessInfo.processInfo.systemUptime
                if now - dwellStart > 0.28, abs(dwellPoint.x - point.x) < 14, abs(dwellPoint.y - point.y) < 14 {
                    folderCandidate = candidate
                } else if abs(dwellPoint.x - point.x) >= 14 || abs(dwellPoint.y - point.y) >= 14 {
                    dwellStart = now
                    dwellPoint = point
                }
                return
            }
        }

        clearHover()
        dwellStart = ProcessInfo.processInfo.systemUptime
        dwellPoint = point
        setGap((page: hit.page, slot: insertionIndex(page: hit.page, slot: hit.slot)))
    }

    // MARK: 拖拽命中辅助

    /// 几何格子 → 该页 items 的下标；若该格子当前是空出来的空位，返回 nil
    private func itemIndex(atPage page: Int, slot: Int) -> Int? {
        var idx = slot
        if let gap, gap.page == page {
            if gap.slot == slot { return nil }
            if gap.slot < slot { idx -= 1 }
        }
        guard idx >= 0, idx < displayPages[page].count else { return nil }
        return idx
    }

    /// 几何格子 → 插入下标
    private func insertionIndex(page: Int, slot: Int) -> Int {
        var idx = slot
        if let gap, gap.page == page, gap.slot <= slot { idx -= 1 }
        return max(0, min(displayPages[page].count, idx))
    }

    /// 指针是否压在某个格子上。已锁定的目标用宽松范围（迟滞），未锁定的用中心 70% 区域。
    private func isOver(point: NSPoint, page: Int, slot: Int, sticky: Bool) -> Bool {
        let frame = frameForItem(page: page, slot: slot)
        // frame 已经是 scrollLayer 内容坐标，减掉 scroll 偏移即可换算到指针所在的内容坐标
        let relX = (point.x + scrollSpring.value - frame.minX) / frame.width
        let relY = (point.y - frame.minY) / frame.height
        if sticky { return relX > -0.2 && relX < 1.2 && relY > -0.15 && relY < 1.15 }
        return relX > 0.15 && relX < 0.85 && relY > 0.1 && relY < 0.9
    }

    private func setHover(_ item: LaunchItem, at point: NSPoint) {
        clearHover()
        hoverItem = item
        folderCandidate = nil
        highlight(item)
        // 目标停止抖动，方便对准
        iconLayers[ObjectIdentifier(item)]?.stopJiggle()
        dwellStart = ProcessInfo.processInfo.systemUptime
        dwellPoint = point
    }

    private func clearHover() {
        guard let previous = hoverItem else { return }
        highlight(previous, on: false)
        // 恢复抖动（还在拖拽中的话）
        if isDragging { iconLayers[ObjectIdentifier(previous)]?.startJiggle() }
        hoverItem = nil
        folderCandidate = nil
    }

    private func setGap(_ newGap: (page: Int, slot: Int)?) {
        if let gap, let newGap, gap.page == newGap.page, gap.slot == newGap.slot { return }
        gap = newGap
        relayout(animated: true)
    }

    private func highlight(_ item: LaunchItem, on: Bool = true) {
        iconLayers[ObjectIdentifier(item)]?.setHighlighted(on)
    }

    private func scheduleAutoPageIfNeeded(at point: NSPoint) {
        autoPageWorkItem?.cancel()
        autoPageWorkItem = nil
        let edge: CGFloat = 90
        var target: Int?
        if point.x < edge, currentPage > 0 { target = currentPage - 1 }
        else if point.x > viewSize.width - edge, currentPage < displayPages.count - 1 { target = currentPage + 1 }
        guard let target else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDragging else { return }
            self.scrollToPage(target, animated: true)
        }
        autoPageWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func finishDrag(at point: NSPoint) {
        guard let item = dragItem, let drag = dragLayer else { return }
        autoPageWorkItem?.cancel()
        autoPageWorkItem = nil
        isDragging = false

        let destination: (page: Int, slot: Int)
        if let hit = slotAt(point: point), hit.page < displayPages.count {
            destination = (hit.page, insertionIndex(page: hit.page, slot: hit.slot))
        } else {
            destination = (currentPage, displayPages[currentPage].count)
        }

        if let candidate = folderCandidate, !item.isFolder {
            // 合并为文件夹 / 投入已有文件夹（LaunchPad 不支持文件夹嵌套）
            if candidate.isFolder {
                library?.removeFromPages(item)
                candidate.children.append(item)
                item.parent = candidate
                library?.save()
            } else {
                let targetSlot = displayPages[destination.page].firstIndex(where: { $0 === candidate })
                    ?? min(destination.slot, max(0, displayPages[destination.page].count - 1))
                library?.createFolder(with: [candidate, item], at: destination.page, slot: targetSlot)
            }
            drag.animateOut(delay: 0) { drag.removeFromSuperlayer() }
        } else {
            let slot = min(destination.slot, displayPages[destination.page].count)
            displayPages[destination.page].insert(item, at: slot)
            library?.moveItem(item, toPage: destination.page, slot: slot)
            // 落位：把拖拽层弹回目标格子
            let frame = frameForItem(page: destination.page, slot: slot)
            let target = CGPoint(x: frame.midX, y: frame.midY)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                drag.removeFromSuperlayer()
                self?.layerPool.append(drag)
                self?.iconLayers[ObjectIdentifier(item)]?.opacity = 1
            }
            drag.add(LPAnimation.pointSpring(params: LPSpring.reflow, from: drag.presentation()?.position ?? drag.position, to: target), forKey: "dropPosition")
            drag.add(LPAnimation.spring("transform.scale", params: LPSpring.reflow, from: 1.14, to: 1.0), forKey: "dropScale")
            drag.position = target
            drag.transform = CATransform3DIdentity
            CATransaction.commit()
        }

        setGap(nil)
        dragItem = nil
        dragLayer = nil
        hoverItem = nil
        folderCandidate = nil
        pendingItem = nil
        pendingLayer = nil
        stopJiggle()
        syncLayers(animate: false)
        delegate?.gridCanvasDidMutateLayout(self)
    }

    private func stopJiggle() {
        for layer in iconLayers.values { layer.stopJiggle(); layer.setHighlighted(false) }
    }

    // MARK: - 外观状态

    func animateLaunch(for item: LaunchItem) {
        iconLayers[ObjectIdentifier(item)]?.animateLaunch()
    }

    func animateIn() {
        zoomLayer.opacity = 1
        zoomLayer.add(LPAnimation.spring("transform.scale", params: LPSpring.openGrid, from: 0.94, to: 1.0), forKey: "zoomIn")
        zoomLayer.transform = CATransform3DIdentity
        var maxDelay: CFTimeInterval = 0
        for (page, items) in displayPages.enumerated() where visiblePageRange().contains(page) {
            for (slot, item) in items.enumerated() {
                guard let layer = iconLayers[ObjectIdentifier(item)] else { continue }
                let col = slot % metrics.columns
                let row = slot / metrics.columns
                let delay = LPAnimation.rippleDelay(column: col, row: row, columns: metrics.columns, rows: metrics.rows)
                maxDelay = max(maxDelay, delay)
                layer.animateIn(delay: delay)
            }
        }
        _ = maxDelay
    }

    func animateOut(completion: @escaping () -> Void) {
        var maxDelay: CFTimeInterval = 0
        for (page, items) in displayPages.enumerated() where visiblePageRange().contains(page) {
            for (slot, item) in items.enumerated() {
                guard let layer = iconLayers[ObjectIdentifier(item)] else { continue }
                let col = slot % metrics.columns
                let row = slot / metrics.columns
                let delay = LPAnimation.rippleDelay(column: col, row: row, columns: metrics.columns, rows: metrics.rows)
                maxDelay = max(maxDelay, delay)
                layer.animateOut(delay: delay)
            }
        }
        zoomLayer.add(LPAnimation.spring("transform.scale", params: LPSpring.closeAll, from: 1.0, to: 0.96), forKey: "zoomOut")
        zoomLayer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDelay + 0.26) { completion() }
    }

    func setFolderMode(_ active: Bool, animated: Bool = true) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        zoomLayer.opacity = active ? 0.18 : 1
        let scale: CGFloat = active ? 0.92 : 1.0
        zoomLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    // MARK: 键盘导航

    func selectFirst() {
        selection = (currentPage, 0)
        applySelection()
    }

    func clearSelection() {
        if let selection, selection.page < displayPages.count,
           selection.slot < displayPages[selection.page].count {
            iconLayers[ObjectIdentifier(displayPages[selection.page][selection.slot])]?.setHighlighted(false)
        }
        selection = nil
    }

    func moveSelection(dx: Int, dy: Int) {
        guard let current = selection else { selectFirst(); return }
        var slot = current.slot + dx + dy * metrics.columns
        var page = current.page
        if slot < 0 {
            page -= 1
            slot = max(0, metrics.capacity + slot)
        } else if slot >= metrics.capacity {
            page += 1
            slot = slot - metrics.capacity
        }
        page = max(0, min(displayPages.count - 1, page))
        while page < displayPages.count - 1 && displayPages[page].isEmpty { page += 1 }
        slot = max(0, min(max(0, displayPages[page].count - 1), slot))
        if page != currentPage { scrollToPage(page, animated: true) }
        clearSelection()
        selection = (page, slot)
        applySelection()
    }

    func activateSelection() {
        guard let selection, selection.page < displayPages.count,
              selection.slot < displayPages[selection.page].count else { return }
        delegate?.gridCanvas(self, didRequestOpen: displayPages[selection.page][selection.slot])
    }

    private func applySelection() {
        guard let selection, selection.page < displayPages.count,
              selection.slot < displayPages[selection.page].count else { return }
        let item = displayPages[selection.page][selection.slot]
        iconLayers[ObjectIdentifier(item)]?.setHighlighted(true)
    }

    func debugBenchmark() {
        let layers = iconLayers.count

        var t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { relayout(animated: false) }
        let relayoutMs = (CFAbsoluteTimeGetCurrent() - t) / 20 * 1000

        var spring = ScalarSpring(value: 0, parameters: LPSpring.paging)
        spring.retarget(1750)
        var steps = 0
        t = CFAbsoluteTimeGetCurrent()
        while !spring.step(dt: 1.0 / 120) && steps < 2000 { steps += 1 }
        let springMs = (CFAbsoluteTimeGetCurrent() - t) * 1000

        t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<200 { applyOffset() }
        let offsetMs = (CFAbsoluteTimeGetCurrent() - t) / 200 * 1000

        t = CFAbsoluteTimeGetCurrent()
        var hits = 0
        for page in displayPages.prefix(1) {
            for item in page {
                let request: IconRequest = item.isFolder
                    ? IconRequest(kind: .folder(childPaths: item.childBundlePaths), key: item.iconVersion, pixelSize: 208)
                    : IconRequest(kind: .app(path: item.bundlePath ?? ""), key: item.iconVersion, pixelSize: 208)
                if IconStore.shared.cached(request) != nil { hits += 1 }
            }
        }
        let cacheMs = (CFAbsoluteTimeGetCurrent() - t) * 1000

        print(String(format: "[LP] bench layers=%d relayout=%.3fms/frame spring_settle=%.1fms(%d steps) offset=%.4fms iconCacheHit=%d/%d in %.2fms",
                     layers, relayoutMs, springMs, steps, offsetMs, hits, displayPages[0].count, cacheMs))
    }

    func debugDump() {
        print("[LP] bounds=\(bounds.size) cols=\(metrics.columns) rows=\(metrics.rows) cell=\(metrics.cellWidth)x\(metrics.cellHeight) capacity=\(metrics.capacity)")
        print("[LP] pages=\(displayPages.count) counts=\(displayPages.map { $0.count }) layers=\(iconLayers.count)")
        for (page, items) in displayPages.enumerated() where visiblePageRange().contains(page) {
            for (slot, item) in items.prefix(6).enumerated() {
                let f = iconLayers[ObjectIdentifier(item)]?.frame ?? .zero
                print("[LP] p\(page)s\(slot) \(item.name) frame=\(Int(f.minX)),\(Int(f.minY)) icon=\(iconLayers[ObjectIdentifier(item)]?.currentIcon() != nil)")
            }
        }
    }

    func frameInWindow(for item: LaunchItem) -> CGRect? {
        guard let layer = iconLayers[ObjectIdentifier(item)] else { return nil }
        var frame = layer.frame
        frame.origin.x -= scrollSpring.value
        return convert(frame, to: nil)
    }
}
