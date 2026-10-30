import AppKit
import QuartzCore

/// 底部页码点：当前页为实心亮点，其余为半透明；可点击跳转，悬停放大
@MainActor
final class PageIndicatorView: NSView {
    var onSelect: ((Int) -> Void)?

    private var dotLayers: [CALayer] = []
    private var pageCountValue = 1
    private var currentValue = 0
    private var hoverIndex: Int?

    private let diameter: CGFloat = 8
    private let spacing: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    func set(pageCount: Int, current: Int) {
        guard pageCount != pageCountValue || current != currentValue else { return }
        pageCountValue = max(1, pageCount)
        currentValue = max(0, min(pageCountValue - 1, current))
        rebuild()
    }

    private func rebuild() {
        dotLayers.forEach { $0.removeFromSuperlayer() }
        dotLayers.removeAll()
        guard pageCountValue > 1 else { return }

        let total = CGFloat(pageCountValue) * diameter + CGFloat(pageCountValue - 1) * spacing
        var x = (bounds.width - total) / 2
        let y = (bounds.height - diameter) / 2
        for index in 0..<pageCountValue {
            let dot = CALayer()
            dot.frame = CGRect(x: x, y: y, width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2
            dot.backgroundColor = NSColor.white.withAlphaComponent(index == currentValue ? 0.95 : 0.3).cgColor
            layer?.addSublayer(dot)
            dotLayers.append(dot)
            x += diameter + spacing
        }
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    func setPresented(_ presented: Bool, animated: Bool) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? 0.28 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = presented ? 1 : 0
        })
        alphaValue = presented ? 1 : 0
    }

    func setDimmed(_ dimmed: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            animator().alphaValue = dimmed ? 0.25 : 1
        }
    }

    // MARK: 交互

    private func indexAt(point: NSPoint) -> Int? {
        guard !dotLayers.isEmpty else { return nil }
        for (index, dot) in dotLayers.enumerated() {
            let expanded = dot.frame.insetBy(dx: -8, dy: -8)
            if expanded.contains(point) { return index }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = indexAt(point: point)
        if index != hoverIndex {
            hoverIndex = index
            for (i, dot) in dotLayers.enumerated() {
                let scale: CGFloat = i == index ? 1.35 : 1.0
                dot.transform = CATransform3DMakeScale(scale, scale, 1)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        for dot in dotLayers { dot.transform = CATransform3DIdentity }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = indexAt(point: point) else { return }
        onSelect?(index)
    }
}
