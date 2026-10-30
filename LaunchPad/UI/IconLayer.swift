import AppKit
import QuartzCore

/// 单个 LaunchPad 条目图层：图标 + 标签 + 选中高亮。
/// 全部用 CALayer 承载，避免 NSView 开销；缩放/淡入/抖动都跑在 render server。
final class IconLayer: CALayer {
    private(set) var item: LaunchItem?
    private let imageLayer = CALayer()
    private let titleLayer = CATextLayer()
    private let highlightLayer = CAShapeLayer()

    private var cellSize: CGSize = .zero
    private var isJiggling = false
    private var isPressed = false
    private var isDimmed = false

    var iconPixelSize: CGFloat = 104

    /// 是否正在抖动（外部只读）
    var jiggling: Bool { isJiggling }

    override init() {
        super.init()
        commonInit()
    }

    /// presentation 拷贝路径：只复制模型属性，不能再往拷贝层里塞子图层
    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    /// 只更新标题（改名时用）。图层是复用的，不重新 configure 的话标签不会跟着变。
    func applyName(_ name: String) {
        titleLayer.string = name
    }

    private func commonInit() {
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.shadowColor = CGColor(gray: 0, alpha: 0.55)
        imageLayer.shadowOpacity = 0.55
        imageLayer.shadowRadius = 6
        imageLayer.shadowOffset = CGSize(width: 0, height: -3)

        titleLayer.alignmentMode = .center
        titleLayer.truncationMode = .end
        titleLayer.isWrapped = false
        titleLayer.contentsScale = 2
        titleLayer.foregroundColor = NSColor.white.cgColor
        titleLayer.shadowColor = CGColor(gray: 0, alpha: 0.65)
        titleLayer.shadowOpacity = 0.65
        titleLayer.shadowRadius = 2
        titleLayer.shadowOffset = CGSize(width: 0, height: -1)

        highlightLayer.fillColor = NSColor.white.withAlphaComponent(0.16).cgColor
        highlightLayer.opacity = 0

        addSublayer(highlightLayer)
        addSublayer(imageLayer)
        addSublayer(titleLayer)
    }

    // MARK: 配置

    func configure(item: LaunchItem, cellSize: CGSize, imageSize: CGFloat, contentsScale: CGFloat) {
        self.item = item
        self.cellSize = cellSize
        self.iconPixelSize = imageSize * contentsScale
        self.contentsScale = contentsScale
        imageLayer.contentsScale = contentsScale
        titleLayer.contentsScale = contentsScale

        bounds = CGRect(origin: .zero, size: cellSize)

        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        titleLayer.font = font
        titleLayer.fontSize = 12.5

        let contentHeight = imageSize + 6 + 16
        let top = (cellSize.height - contentHeight) / 2
        let imageX = (cellSize.width - imageSize) / 2
        imageLayer.frame = CGRect(x: imageX, y: cellSize.height - top - imageSize,
                                  width: imageSize, height: imageSize)
        // 显式给阴影形状：否则每个图标都要走一次离屏渲染去算阴影轮廓。
        // 中间页会同时存活 3 页（135 个图层），这一步能省掉 135 次离屏渲染。
        // macOS 图标是超椭圆，0.22 的圆角比例足够贴合，肉眼无差别。
        let shadowRadiusRatio = imageSize * 0.22
        imageLayer.shadowPath = CGPath(roundedRect: imageLayer.bounds,
                                       cornerWidth: shadowRadiusRatio,
                                       cornerHeight: shadowRadiusRatio,
                                       transform: nil)
        titleLayer.frame = CGRect(x: 4, y: cellSize.height - top - imageSize - 6 - 16,
                                  width: cellSize.width - 8, height: 16)

        let highlightRect = CGRect(x: imageX - 14, y: cellSize.height - top - imageSize - 12,
                                   width: imageSize + 28, height: imageSize + 32)
        highlightLayer.frame = highlightRect
        highlightLayer.path = CGPath(roundedRect: highlightLayer.bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)

        titleLayer.string = item.name
    }

    private var currentImage: CGImage?

    func applyIcon(_ image: CGImage?) {
        currentImage = image
        imageLayer.contents = image
    }

    func currentIcon() -> CGImage? {
        currentImage
    }

    // MARK: 交互态

    func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        let anim = LPAnimation.spring("transform.scale", params: LPSpring.press,
                                      from: presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat,
                                      to: pressed ? 0.92 : 1.0)
        add(anim, forKey: "press")
        transform = CATransform3DMakeScale(pressed ? 0.92 : 1.0, pressed ? 0.92 : 1.0, 1)
    }

    func setHighlighted(_ highlighted: Bool) {
        highlightLayer.opacity = highlighted ? 1 : 0
    }

    func setDimmed(_ dimmed: Bool, animated: Bool) {
        isDimmed = dimmed
        if animated {
            add(LPAnimation.fade(duration: LPTiming.searchFade, to: dimmed ? 0.08 : 1), forKey: "dim")
        }
        opacity = dimmed ? 0.08 : 1
    }

    // MARK: 抖动（编辑态）

    func startJiggle() {
        guard !isJiggling else { return }
        isJiggling = true
        let anim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let a = LPTiming.jiggleAngle
        anim.values = [a, -a, a]
        anim.keyTimes = [0, 0.5, 1]
        anim.duration = LPTiming.jigglePeriod
        anim.repeatCount = .infinity
        anim.timeOffset = Double.random(in: 0..<LPTiming.jigglePeriod)
        anim.isRemovedOnCompletion = false
        add(anim, forKey: "jiggle")
    }

    func stopJiggle() {
        guard isJiggling else { return }
        isJiggling = false
        removeAnimation(forKey: "jiggle")
        let anim = LPAnimation.spring("transform.rotation.z", params: LPSpring.reflow, to: 0)
        add(anim, forKey: "jiggleStop")
        transform = CATransform3DIdentity
    }

    // MARK: 入场 / 出场

    func animateIn(delay: CFTimeInterval) {
        let now = CACurrentMediaTime()
        opacity = 0
        transform = CATransform3DMakeScale(0.62, 0.62, 1)
        let scale = LPAnimation.spring("transform.scale", params: LPSpring.openIcon,
                                       from: 0.62, to: 1.0, begin: delay)
        let fade = LPAnimation.fade(duration: 0.20, from: 0, to: 1, begin: delay)
        add(scale, forKey: "appearScale")
        add(fade, forKey: "appearFade")
        opacity = 1
        transform = CATransform3DIdentity
        _ = now
    }

    func animateOut(delay: CFTimeInterval, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        add(LPAnimation.spring("transform.scale", params: LPSpring.closeAll, from: 1.0, to: 0.72, begin: delay), forKey: "outScale")
        add(LPAnimation.fade(duration: 0.18, from: 1, to: 0, begin: delay), forKey: "outFade")
        opacity = 0
        transform = CATransform3DMakeScale(0.72, 0.72, 1)
        CATransaction.commit()
    }

    /// 点击启动：图标弹大并淡出
    func animateLaunch(completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let scale = LPAnimation.spring("transform.scale", params: LPSpring.folder, from: 1.0, to: 1.35)
        let fade = LPAnimation.fade(duration: LPTiming.launchPop, from: 1, to: 0)
        add(scale, forKey: "launchScale")
        add(fade, forKey: "launchFade")
        opacity = 0
        transform = CATransform3DMakeScale(1.35, 1.35, 1)
        CATransaction.commit()
    }

    func resetTransientState() {
        removeAllAnimations()
        opacity = 1
        transform = CATransform3DIdentity
        isPressed = false
    }
}
