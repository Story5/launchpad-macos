import CoreVideo
import Dispatch
import Foundation

// MARK: - 标量弹簧积分器（半隐式欧拉 + 子步进，保证任意帧率下行为一致）

struct ScalarSpring {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    var parameters: SpringParameters

    init(value: CGFloat, parameters: SpringParameters) {
        self.value = value
        self.target = value
        self.parameters = parameters
    }

    mutating func retarget(_ newTarget: CGFloat, initialVelocity: CGFloat? = nil) {
        target = newTarget
        if let initialVelocity { velocity += initialVelocity }
    }

    mutating func jump(to value: CGFloat) {
        self.value = value
        self.target = value
        self.velocity = 0
    }

    /// 步进一个时间片，返回是否已经静止
    @discardableResult
    mutating func step(dt: CGFloat) -> Bool {
        let maxStep: CGFloat = 1 / 240
        let clamped = min(0.05, max(0.0005, dt))
        let iterations = max(1, min(8, Int(ceil(clamped / maxStep))))
        let h = clamped / CGFloat(iterations)
        let k = parameters.stiffness
        let c = parameters.damping
        for _ in 0..<iterations {
            let force = -k * (value - target) - c * velocity
            velocity += force * h
            value += velocity * h
        }
        if abs(value - target) < 0.05 && abs(velocity) < 2 {
            value = target
            velocity = 0
            return true
        }
        return false
    }

    var isSettled: Bool { value == target && velocity == 0 }
}

// MARK: - CVDisplayLink 帧驱动（自动跟随 60/120Hz ProMotion）

final class FrameDriver {
    private var link: CVDisplayLink?
    private let box = Box()
    private var running = false

    final class Box: @unchecked Sendable {
        var onFrame: ((CFTimeInterval) -> Void)?
        var lastTime: Double = 0
    }

    var onFrame: ((CFTimeInterval) -> Void)? {
        get { box.onFrame }
        set { box.onFrame = newValue }
    }

    var isRunning: Bool { running }

    func start() {
        guard !running else { return }
        var created: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard let created else { return }
        link = created
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        CVDisplayLinkSetOutputCallback(created, displayLinkCallback, ctx)
        CVDisplayLinkStart(created)
        running = true
    }

    func stop() {
        guard running, let link else { return }
        CVDisplayLinkStop(link)
        self.link = nil
        box.lastTime = 0
        running = false
    }

    deinit { stop() }
}

private func displayLinkCallback(_ displayLink: CVDisplayLink,
                                 _ now: UnsafePointer<CVTimeStamp>,
                                 _ outputTime: UnsafePointer<CVTimeStamp>,
                                 _ flagsIn: UInt64,
                                 _ flagsOut: UnsafeMutablePointer<UInt64>,
                                 _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return kCVReturnSuccess }
    let box = Unmanaged<FrameDriver.Box>.fromOpaque(context).takeUnretainedValue()
    let ts = now.pointee
    let seconds = Double(ts.videoTime) / Double(max(1, ts.videoTimeScale))
    var dt: Double = 1 / 60
    if box.lastTime > 0 {
        dt = min(0.05, max(0.0005, seconds - box.lastTime))
    }
    box.lastTime = seconds
    DispatchQueue.main.async { box.onFrame?(dt) }
    return kCVReturnSuccess
}
