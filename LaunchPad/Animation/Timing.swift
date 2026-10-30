import AppKit
import QuartzCore

// MARK: - 弹簧参数（response/dampingRatio → CASpringAnimation 的 stiffness/damping）

struct SpringParameters: Hashable, Sendable {
    var response: CGFloat       // 响应时间（秒），越小越快
    var dampingRatio: CGFloat   // 阻尼比，1 = 临界阻尼无回弹

    var stiffness: CGFloat {
        let w = 2 * CGFloat.pi / response
        return w * w
    }
    var damping: CGFloat { 4 * CGFloat.pi * dampingRatio / response }

    init(response: CGFloat, dampingRatio: CGFloat) {
        self.response = response
        self.dampingRatio = dampingRatio
    }
}

/// 对齐原生 LaunchPad 的动效参数表（集中可调）
enum LPSpring {
    static let backdrop   = SpringParameters(response: 0.40, dampingRatio: 1.00)
    static let openGrid   = SpringParameters(response: 0.42, dampingRatio: 0.80)
    static let openIcon   = SpringParameters(response: 0.36, dampingRatio: 0.72)
    static let closeAll   = SpringParameters(response: 0.30, dampingRatio: 0.92)
    static let paging     = SpringParameters(response: 0.42, dampingRatio: 0.90)
    static let reflow     = SpringParameters(response: 0.34, dampingRatio: 0.72)
    static let folder     = SpringParameters(response: 0.50, dampingRatio: 0.84)
    static let press      = SpringParameters(response: 0.20, dampingRatio: 0.68)
    static let lift       = SpringParameters(response: 0.26, dampingRatio: 0.70)
    static let inertia    = SpringParameters(response: 0.62, dampingRatio: 1.00)
}

enum LPTiming {
    static let backdropIn: CFTimeInterval   = 0.34
    static let backdropOut: CFTimeInterval  = 0.26
    static let rippleStep: CFTimeInterval   = 0.010   // 每个格子的波纹延迟步进
    static let rippleMax: CFTimeInterval    = 0.15    // 波纹最大延迟
    static let searchFade: CFTimeInterval   = 0.20
    static let launchPop: CFTimeInterval    = 0.22
    static let jigglePeriod: CFTimeInterval = 0.22
    static let jiggleAngle: CGFloat         = 0.028   // 弧度 ≈ 1.6°
    /// 长按多久进入抖动（编辑）模式，对齐原生 LaunchPad 的手感
    static let longPress: CFTimeInterval    = 0.5
}

// MARK: - CA 动画工厂（全部跑在 render server，主线程零开销，天然 120Hz）

enum LPAnimation {
    /// 全局时间缩放（1 = 正常，>1 为慢动作，便于逐帧验证动效）
    nonisolated(unsafe) static var timeScale: CGFloat = 1

    private static var scale: CGFloat { max(0.05, timeScale) }
    static func scaledStiffness(_ params: SpringParameters) -> CGFloat { params.stiffness / (scale * scale) }
    static func scaledDamping(_ params: SpringParameters) -> CGFloat { params.damping / scale }

    /// 标量弹簧（opacity / transform.scale / cornerRadius …）
    static func spring(_ keyPath: String,
                       params: SpringParameters,
                       from: CGFloat? = nil,
                       to: CGFloat,
                       initialVelocity: CGFloat = 0,
                       begin: CFTimeInterval = 0) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = scaledStiffness(params)
        a.damping = scaledDamping(params)
        a.initialVelocity = initialVelocity
        if let from { a.fromValue = from }
        a.toValue = to
        a.beginTime = begin > 0 ? CACurrentMediaTime() + begin * scale : 0
        // 动画结束后必须移除。若用 isRemovedOnCompletion = false 永久挂着，
        // render server 会保留按起始 scale 栅格化的缓存再放大显示 → 整页发虚。
        // 所有调用点都会在 add 之后把 model 值设成终值，所以移除后不会跳变。
        a.isRemovedOnCompletion = true
        a.fillMode = .both
        return a
    }

    static func pointSpring(_ keyPath: String = "position",
                            params: SpringParameters,
                            from: CGPoint? = nil,
                            to: CGPoint,
                            begin: CFTimeInterval = 0) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = scaledStiffness(params)
        a.damping = scaledDamping(params)
        if let from { a.fromValue = NSValue(point: from) }
        a.toValue = NSValue(point: to)
        a.beginTime = begin > 0 ? CACurrentMediaTime() + begin * scale : 0
        // 同 spring：结束后必须移除，否则动画永久挂在图层上。
        a.isRemovedOnCompletion = true
        a.fillMode = .both
        return a
    }

    static func fade(duration: CFTimeInterval,
                     from: CGFloat? = nil,
                     to: CGFloat,
                     begin: CFTimeInterval = 0,
                     timing: CAMediaTimingFunctionName = .easeOut) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        if let from { a.fromValue = from }
        a.toValue = to
        a.duration = duration * scale
        a.timingFunction = CAMediaTimingFunction(name: timing)
        a.beginTime = begin > 0 ? CACurrentMediaTime() + begin * scale : 0
        // 同 spring：结束后必须移除，否则动画永久挂在图层上。
        a.isRemovedOnCompletion = true
        a.fillMode = .both
        return a
    }

    /// 以网格中心为原点的波纹延迟（原生 LaunchPad 的图标是「由中心向外」浮现）
    static func rippleDelay(column: Int, row: Int, columns: Int, rows: Int) -> CFTimeInterval {
        let cx = CGFloat(columns - 1) / 2
        let cy = CGFloat(rows - 1) / 2
        let dx = CGFloat(column) - cx
        let dy = CGFloat(row) - cy
        let dist = sqrt(dx * dx + dy * dy)
        let maxDist = sqrt(cx * cx + cy * cy) + 0.001
        return min(LPTiming.rippleMax, CFTimeInterval(dist / maxDist) * LPTiming.rippleMax)
    }
}

// MARK: - 网格度量（对齐原生：图标尺寸固定，屏幕越大边距越大）

struct GridMetrics {
    var imageSize: CGFloat = 104
    var cellWidth: CGFloat = 176
    var cellHeight: CGFloat = 158
    var columns: Int = 7
    var rows: Int = 5
    var topInset: CGFloat = 128
    var bottomInset: CGFloat = 92
    var horizontalMargin: CGFloat = 90

    var gridWidth: CGFloat { CGFloat(columns) * cellWidth }
    var gridHeight: CGFloat { CGFloat(rows) * cellHeight }
    var capacity: Int { columns * rows }

    /// 网格左上角（AppKit 坐标，y 向下）
    func gridOrigin(viewSize: CGSize) -> CGPoint {
        let usableH = viewSize.height - topInset - bottomInset
        let x = (viewSize.width - gridWidth) / 2
        let y = topInset + (usableH - gridHeight) / 2
        return CGPoint(x: x, y: y)
    }

    /// 网格底边在 layer 坐标（y 向上）中的位置
    func gridBottomY(viewSize: CGSize) -> CGFloat {
        viewSize.height - gridOrigin(viewSize: viewSize).y - gridHeight
    }

    static func make(viewSize: CGSize) -> GridMetrics {
        var m = GridMetrics()
        let margin = max(70, min(160, viewSize.width * 0.07))
        m.horizontalMargin = margin
        m.columns = max(3, min(9, Int((viewSize.width - margin * 2) / m.cellWidth)))

        let usableH = viewSize.height - m.topInset - m.bottomInset
        var cellH = usableH / 5
        cellH = max(124, min(158, cellH))
        m.cellHeight = cellH
        m.rows = max(3, min(6, Int(usableH / cellH)))
        m.imageSize = min(104, cellH * 0.68)
        return m
    }
}

// MARK: - 文件夹面板度量

struct FolderMetrics {
    var imageSize: CGFloat = 84
    var cellWidth: CGFloat = 118
    var cellHeight: CGFloat = 116
    var padding: CGFloat = 26
    var titleHeight: CGFloat = 46
    var columns: Int = 3
    var rows: Int = 3
    var cornerRadius: CGFloat = 30

    var capacity: Int { columns * rows }
    var gridWidth: CGFloat { CGFloat(columns) * cellWidth }
    var gridHeight: CGFloat { CGFloat(rows) * cellHeight }
    var panelSize: CGSize {
        CGSize(width: gridWidth + padding * 2, height: gridHeight + padding + titleHeight)
    }

    static func make(itemCount: Int, maxSize: CGSize) -> FolderMetrics {
        var m = FolderMetrics()
        let cols = Int(ceil(sqrt(Double(max(1, itemCount)))))
        m.columns = max(3, min(5, cols))
        m.rows = max(1, min(3, Int(ceil(Double(itemCount) / Double(m.columns)))))
        // 尺寸受屏幕约束时按比例缩
        let maxW = maxSize.width * 0.72
        let maxH = maxSize.height * 0.72
        var scale: CGFloat = 1
        if m.panelSize.width > maxW { scale = min(scale, maxW / m.panelSize.width) }
        if m.panelSize.height > maxH { scale = min(scale, maxH / m.panelSize.height) }
        m.imageSize *= scale
        m.cellWidth *= scale
        m.cellHeight *= scale
        m.padding *= scale
        m.titleHeight *= scale
        m.cornerRadius *= scale
        return m
    }
}
