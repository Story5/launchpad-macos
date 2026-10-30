import AppKit
import QuartzCore

@MainActor protocol FolderPanelDelegate: AnyObject {
    func folderPanel(_ panel: FolderPanelView, didRequestOpen item: LaunchItem)
    func folderPanelDidClose(_ panel: FolderPanelView)
    func folderPanelDidChangeContent(_ panel: FolderPanelView)
}

/// 文件夹面板：从图标位置形变展开（bounds/position/cornerRadius 三属性弹簧同动），
/// 内部图标以波纹式延迟淡入，点击外部收起。
@MainActor
final class FolderPanelView: NSView {
    weak var delegate: FolderPanelDelegate?

    private let shadowLayer = CALayer()
    private let panelLayer = CALayer()
    private let titleLayer = CATextLayer()
    private let iconContainer = CALayer()
    private let dotsLayer = CALayer()
    private var sheenLayer: CAGradientLayer?
    private var iconLayers: [ObjectIdentifier: IconLayer] = [:]

    private var folder: LaunchItem?
    /// 当前打开的文件夹（供外部在改名后刷新网格标签）
    var currentFolder: LaunchItem? { folder }
    private var metrics = FolderMetrics()
    private var pages: [[LaunchItem]] = [[]]
    private var page = 0
    private var isOpen = false
    private var originFrame: CGRect = .zero
    private var renameField: NSTextField?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        shadowLayer.backgroundColor = CGColor(gray: 0.05, alpha: 0.42)
        shadowLayer.shadowColor = CGColor(gray: 0, alpha: 0.65)
        shadowLayer.shadowOpacity = 0.65
        shadowLayer.shadowRadius = 38
        shadowLayer.shadowOffset = CGSize(width: 0, height: -10)

        panelLayer.backgroundColor = NSColor.white.withAlphaComponent(0.30).cgColor
        panelLayer.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
        panelLayer.borderWidth = 0.5
        panelLayer.masksToBounds = true

        titleLayer.alignmentMode = .center
        titleLayer.truncationMode = .middle
        titleLayer.foregroundColor = NSColor.white.cgColor
        titleLayer.contentsScale = 2

        layer?.addSublayer(shadowLayer)
        layer?.addSublayer(panelLayer)

        // 顶部高光渐变，让面板更接近原生磨砂质感
        let sheen = CAGradientLayer()
        sheen.colors = [NSColor.white.withAlphaComponent(0.10).cgColor,
                        NSColor.white.withAlphaComponent(0.0).cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.45)
        sheen.name = "sheen"
        panelLayer.addSublayer(sheen)
        sheenLayer = sheen

        panelLayer.addSublayer(iconContainer)
        panelLayer.addSublayer(titleLayer)
        panelLayer.addSublayer(dotsLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 打开 / 关闭

    func open(folder: LaunchItem, originFrame: CGRect, contentsScale: CGFloat) {
        self.folder = folder
        self.originFrame = originFrame
        self.metrics = FolderMetrics.make(itemCount: folder.children.count, maxSize: bounds.size)
        buildPages()
        isOpen = true

        let size = metrics.panelSize
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let frame = CGRect(x: center.x - size.width / 2,
                           y: center.y - size.height / 2,
                           width: size.width,
                           height: size.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panelLayer.frame = frame
        panelLayer.cornerRadius = metrics.cornerRadius
        shadowLayer.frame = frame
        shadowLayer.cornerRadius = metrics.cornerRadius
        iconContainer.frame = panelLayer.bounds
        sheenLayer?.frame = panelLayer.bounds
        titleLayer.frame = CGRect(x: 20,
                                  y: size.height - metrics.titleHeight,
                                  width: size.width - 40,
                                  height: metrics.titleHeight * 0.62)
        dotsLayer.frame = CGRect(x: 0, y: 10, width: size.width, height: 12)
        CATransaction.commit()

        titleLayer.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLayer.fontSize = 17
        titleLayer.string = folder.name
        panelLayer.contentsScale = contentsScale

        buildIconLayers(contentsScale: contentsScale)
        updateDots()

        // 形变：从图标矩形展开到面板矩形
        let fromScaleX = max(0.02, originFrame.width / size.width)
        let fromScaleY = max(0.02, originFrame.height / size.height)
        let fromPosition = CGPoint(x: originFrame.midX, y: originFrame.midY)
        let toPosition = CGPoint(x: frame.midX, y: frame.midY)

        for l in [panelLayer, shadowLayer] {
            l.add(LPAnimation.pointSpring(params: LPSpring.folder, from: fromPosition, to: toPosition), forKey: "folderPosition")
            let anim = CASpringAnimation(keyPath: "transform")
            anim.mass = 1
            anim.stiffness = LPAnimation.scaledStiffness(LPSpring.folder)
            anim.damping = LPAnimation.scaledDamping(LPSpring.folder)
            anim.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(fromScaleX, fromScaleY, 1))
            anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            anim.isRemovedOnCompletion = false
            anim.fillMode = .both
            l.add(anim, forKey: "folderScale")
            l.add(LPAnimation.spring("cornerRadius", params: LPSpring.folder, from: metrics.imageSize * 0.22, to: metrics.cornerRadius), forKey: "folderRadius")
        }

        // 图标与标题延迟淡入
        titleLayer.opacity = 0
        titleLayer.add(LPAnimation.fade(duration: 0.22, from: 0, to: 1, begin: 0.10), forKey: "titleIn")
        titleLayer.opacity = 1

        for (index, layer) in iconLayers.values.enumerated() {
            let delay = 0.10 + Double(index % 9) * 0.012
            layer.opacity = 0
            layer.add(LPAnimation.fade(duration: 0.20, from: 0, to: 1, begin: delay), forKey: "itemIn")
            layer.add(LPAnimation.spring("transform.scale", params: LPSpring.openIcon, from: 0.72, to: 1.0, begin: delay), forKey: "itemScale")
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
        }
    }

    func close(completion: (() -> Void)? = nil) {
        guard isOpen else { completion?(); return }
        isOpen = false
        dismissRename(commit: false)

        let size = metrics.panelSize
        let currentFrame = panelLayer.frame
        let fromScaleX = max(0.02, originFrame.width / size.width)
        let fromScaleY = max(0.02, originFrame.height / size.height)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.removeFromSuperview()
            completion?()
        }
        for l in [panelLayer, shadowLayer] {
            l.add(LPAnimation.pointSpring(params: LPSpring.closeAll,
                                          from: l.presentation()?.position ?? l.position,
                                          to: CGPoint(x: originFrame.midX, y: originFrame.midY)), forKey: "folderPosition")
            let anim = CASpringAnimation(keyPath: "transform")
            anim.mass = 1
            anim.stiffness = LPAnimation.scaledStiffness(LPSpring.closeAll)
            anim.damping = LPAnimation.scaledDamping(LPSpring.closeAll)
            anim.fromValue = l.presentation()?.value(forKeyPath: "transform")
            anim.toValue = NSValue(caTransform3D: CATransform3DMakeScale(fromScaleX, fromScaleY, 1))
            anim.isRemovedOnCompletion = false
            anim.fillMode = .both
            l.add(anim, forKey: "folderScale")
            l.add(LPAnimation.spring("cornerRadius", params: LPSpring.closeAll, from: metrics.cornerRadius, to: metrics.imageSize * 0.22), forKey: "folderRadius")
        }
        for layer in iconLayers.values {
            layer.add(LPAnimation.fade(duration: 0.14, from: 1, to: 0), forKey: "itemOut")
            layer.opacity = 0
        }
        titleLayer.add(LPAnimation.fade(duration: 0.12, from: 1, to: 0), forKey: "titleOut")
        titleLayer.opacity = 0
        _ = currentFrame
        CATransaction.commit()
    }

    var isPanelOpen: Bool { isOpen }

    // MARK: 内容

    private func buildPages() {
        guard let folder else { pages = [[]]; return }
        let capacity = metrics.capacity
        var result: [[LaunchItem]] = []
        var index = 0
        while index < folder.children.count {
            let end = min(index + capacity, folder.children.count)
            result.append(Array(folder.children[index..<end]))
            index = end
        }
        pages = result.isEmpty ? [[]] : result
        page = min(page, max(0, pages.count - 1))
    }

    private func buildIconLayers(contentsScale: CGFloat) {
        for layer in iconLayers.values { layer.removeFromSuperlayer() }
        iconLayers.removeAll()

        for (pageIndex, items) in pages.enumerated() {
            for (slot, item) in items.enumerated() {
                let layer = IconLayer()
                layer.configure(item: item,
                                cellSize: CGSize(width: metrics.cellWidth, height: metrics.cellHeight),
                                imageSize: metrics.imageSize,
                                contentsScale: contentsScale)
                let frame = frameForItem(page: pageIndex, slot: slot)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = frame
                CATransaction.commit()
                iconContainer.addSublayer(layer)
                iconLayers[ObjectIdentifier(item)] = layer

                let request: IconRequest = item.isFolder
                    ? IconRequest(kind: .folder(childPaths: item.childBundlePaths), key: item.iconVersion, pixelSize: Int(metrics.imageSize * contentsScale))
                    : IconRequest(kind: .app(path: item.bundlePath ?? ""), key: item.iconVersion, pixelSize: Int(metrics.imageSize * contentsScale))
                if let cached = IconStore.shared.cached(request) {
                    layer.applyIcon(cached)
                } else {
                    IconStore.shared.fetch(request) { [weak layer] image in
                        guard let layer, layer.item === item else { return }
                        layer.applyIcon(image)
                    }
                }
            }
        }
        applyPageOffset(animated: false)
    }

    private func frameForItem(page pageIndex: Int, slot: Int) -> CGRect {
        let col = slot % metrics.columns
        let row = slot / metrics.columns
        let gridX = (metrics.panelSize.width - metrics.gridWidth) / 2
        let top = metrics.titleHeight
        let x = CGFloat(pageIndex) * metrics.panelSize.width + gridX + CGFloat(col) * metrics.cellWidth
        let yTop = top + CGFloat(row) * metrics.cellHeight
        let y = metrics.panelSize.height - yTop - metrics.cellHeight
        return CGRect(x: x, y: y, width: metrics.cellWidth, height: metrics.cellHeight)
    }

    private func applyPageOffset(animated: Bool) {
        let offset = -CGFloat(page) * metrics.panelSize.width
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        iconContainer.transform = CATransform3DMakeTranslation(offset, 0, 0)
        CATransaction.commit()
        updateDots()
    }

    private func updateDots() {
        dotsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard pages.count > 1 else { return }
        let diameter: CGFloat = 7
        let spacing: CGFloat = 14
        let total = CGFloat(pages.count) * diameter + CGFloat(pages.count - 1) * spacing
        var x = (metrics.panelSize.width - total) / 2
        for index in 0..<pages.count {
            let dot = CALayer()
            dot.frame = CGRect(x: x, y: (12 - diameter) / 2, width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2
            dot.backgroundColor = NSColor.white.withAlphaComponent(index == page ? 0.95 : 0.32).cgColor
            dotsLayer.addSublayer(dot)
            x += diameter + spacing
        }
    }

    // MARK: 事件

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let panelFrame = panelLayer.presentation()?.frame ?? panelLayer.frame
        guard panelFrame.contains(point) else {
            close()
            delegate?.folderPanelDidClose(self)
            return
        }
        // 标题：双击重命名
        let titleFrame = titleLayer.frame.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        if titleFrame.contains(point) {
            if event.clickCount == 2 { beginRename() }
            return
        }
        guard let hit = itemAt(point: point) else { return }
        delegate?.folderPanel(self, didRequestOpen: hit.item)
    }

    override func scrollWheel(with event: NSEvent) {
        guard pages.count > 1 else { return }
        // scrollingDeltaX 是手指移动方向：双指向左滑 → deltaX < 0 → 下一页（与主网格同一约定）
        if event.scrollingDeltaX > 12 { showPage(max(0, page - 1)) }
        else if event.scrollingDeltaX < -12 { showPage(min(pages.count - 1, page + 1)) }
    }

    private func showPage(_ index: Int) {
        page = max(0, min(pages.count - 1, index))
        applyPageOffset(animated: true)
    }

    private func itemAt(point: NSPoint) -> (item: LaunchItem, layer: IconLayer)? {
        let panelFrame = panelLayer.frame
        let local = CGPoint(x: point.x - panelFrame.minX + CGFloat(page) * metrics.panelSize.width,
                            y: point.y - panelFrame.minY)
        let pageIndex = Int(floor(local.x / metrics.panelSize.width))
        guard pageIndex < pages.count, pageIndex >= 0 else { return nil }
        let gridX = (metrics.panelSize.width - metrics.gridWidth) / 2
        let col = Int(floor((local.x - CGFloat(pageIndex) * metrics.panelSize.width - gridX) / metrics.cellWidth))
        let appkitY = metrics.panelSize.height - local.y
        let row = Int(floor((appkitY - metrics.titleHeight) / metrics.cellHeight))
        guard col >= 0, col < metrics.columns, row >= 0, row < metrics.rows else { return nil }
        let slot = row * metrics.columns + col
        guard slot < pages[pageIndex].count else { return nil }
        let item = pages[pageIndex][slot]
        guard let layer = iconLayers[ObjectIdentifier(item)] else { return nil }
        return (item, layer)
    }

    // MARK: 重命名

    private func beginRename() {
        guard let folder, renameField == nil else { return }
        let panelFrame = panelLayer.frame
        let field = NSTextField(frame: CGRect(x: panelFrame.minX + 20,
                                              y: panelFrame.maxY - metrics.titleHeight + 4,
                                              width: panelFrame.width - 40,
                                              height: 26))
        field.stringValue = folder.name
        field.isBezeled = false
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = false
        field.textColor = .white
        field.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        field.alignment = .center
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)
        renameField = field
        window?.makeFirstResponder(field)
    }

    private func dismissRename(commit: Bool) {
        guard let field = renameField else { return }
        if commit, let folder, !field.stringValue.isEmpty {
            folder.name = field.stringValue
            titleLayer.string = folder.name
            delegate?.folderPanelDidChangeContent(self)
        }
        field.removeFromSuperview()
        renameField = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            if renameField != nil { dismissRename(commit: false); return }
            close()
            delegate?.folderPanelDidClose(self)
            return
        }
        super.keyDown(with: event)
    }
}

extension FolderPanelView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            dismissRename(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismissRename(commit: false)
            return true
        }
        return false
    }
}
