import AppKit
import CoreImage
import QuartzCore

/// 桌面背景层：清晰壁纸 + 预渲染模糊图交叉淡入 + 变暗遮罩。
/// 模糊只算一次并缓存，运行期零实时滤镜开销 —— 这是原生 LaunchPad 的做法。
@MainActor
final class BackdropView: NSView {
    private let sharpLayer = CALayer()
    private let blurLayer = CALayer()
    private let dimLayer = CALayer()
    private let folderDimLayer = CALayer()

    private var screen: NSScreen?
    private var prepared = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(sharpLayer)
        layer?.addSublayer(blurLayer)
        layer?.addSublayer(dimLayer)
        layer?.addSublayer(folderDimLayer)

        for l in [sharpLayer, blurLayer] {
            l.contentsGravity = .resizeAspectFill
            l.masksToBounds = true
        }
        dimLayer.backgroundColor = CGColor(gray: 0.02, alpha: 0.34)
        folderDimLayer.backgroundColor = CGColor(gray: 0.0, alpha: 0.26)
        dimLayer.opacity = 0
        blurLayer.opacity = 0
        folderDimLayer.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sharpLayer.frame = bounds
        blurLayer.frame = bounds
        dimLayer.frame = bounds
        folderDimLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [sharpLayer, blurLayer] { l.contentsScale = scale }
    }

    func prepare(screen: NSScreen) {
        self.screen = screen
        let scale = window?.backingScaleFactor ?? screen.backingScaleFactor
        sharpLayer.contentsScale = scale
        blurLayer.contentsScale = scale

        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        if let url, let source = WallpaperLoader.loadImage(url: url) {
            sharpLayer.contents = source
            if let blurred = WallpaperLoader.blurredCopy(of: source) {
                blurLayer.contents = blurred
            } else {
                blurLayer.contents = source
            }
        } else {
            // 拿不到壁纸（动态壁纸/权限）时降级为系统灰色渐变
            sharpLayer.contents = WallpaperLoader.fallbackGradient(size: CGSize(width: 512, height: 512))
            blurLayer.contents = sharpLayer.contents
        }
        prepared = true
    }

    // MARK: 状态切换

    func setPresented(_ presented: Bool, animated: Bool) {
        let duration = animated ? (presented ? LPTiming.backdropIn : LPTiming.backdropOut) : 0
        let scale: CGFloat = presented ? 1.06 : 1.0
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        blurLayer.opacity = presented ? 1 : 0
        dimLayer.opacity = presented ? 1 : 0
        let t = CATransform3DMakeScale(scale, scale, 1)
        sharpLayer.transform = t
        blurLayer.transform = t
        CATransaction.commit()
    }

    func setFolderMode(_ active: Bool, animated: Bool = true) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.28 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        folderDimLayer.opacity = active ? 1 : 0
        CATransaction.commit()
    }
}

// MARK: - 壁纸加载 / 预模糊

enum WallpaperLoader {
    private static let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [.useSoftwareRenderer: false, .cacheIntermediates: false]
        return CIContext(options: options)
    }()

    static func loadImage(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 降采样后做一次高斯模糊（一次性），结果被图层放大使用，肉眼等价全分辨率模糊
    static func blurredCopy(of image: CGImage) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > 8 else { return nil }
        let smallSize = max(64, longSide / 4)
        guard let small = IconStore.rasterize(image, pixelSize: smallSize) else { return nil }
        let input = CIImage(cgImage: small).clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(28, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: output.extent)
    }

    static func fallbackGradient(size: CGSize) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: Int(size.width),
                                  height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [
            CGColor(red: 0.18, green: 0.24, blue: 0.36, alpha: 1),
            CGColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1)
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: size.height),
                                   end: CGPoint(x: size.width, y: 0),
                                   options: [])
        }
        return ctx.makeImage()
    }
}
