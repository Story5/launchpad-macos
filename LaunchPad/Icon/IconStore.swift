import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private final class IconBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// 回调包装：让非 Sendable 的主线程闭包可以安全地跨队列传递
private final class CallbackBox: @unchecked Sendable {
    let fn: (CGImage?) -> Void
    init(_ fn: @escaping (CGImage?) -> Void) { self.fn = fn }
}

struct IconRequest: Sendable {
    enum Kind: Sendable {
        case app(path: String)
        case folder(childPaths: [String])
        case unknown
    }
    var kind: Kind
    var key: String
    var pixelSize: Int
}

/// 图标加载与栅格化：内存缓存 + 磁盘缓存 + 后台解码，主线程只做赋值
final class IconStore: @unchecked Sendable {
    static let shared = IconStore()

    private let memory = NSCache<NSString, IconBox>()
    private let queue = DispatchQueue(label: "com.launchpad.icon", qos: .userInitiated, attributes: .concurrent)
    private let cacheDir: URL

    init() {
        memory.countLimit = 600
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("LaunchPadReplica/IconCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - 同步取（仅命中内存时返回）

    func cached(_ request: IconRequest) -> CGImage? {
        memory.object(forKey: cacheKey(request) as NSString)?.image
    }

    // MARK: - 异步取（内存 → 磁盘 → 生成 → NSWorkspace 兜底）

    func fetch(_ request: IconRequest, completion: @escaping (CGImage?) -> Void) {
        let key = cacheKey(request)
        if let hit = memory.object(forKey: key as NSString) {
            completion(hit.image)
            return
        }
        let boxed = CallbackBox(completion)
        queue.async {
            if let img = self.loadFromDisk(key: key) {
                self.memory.setObject(IconBox(img), forKey: key as NSString)
                DispatchQueue.main.async { boxed.fn(img) }
                return
            }
            if let img = Self.generate(request) {
                self.memory.setObject(IconBox(img), forKey: key as NSString)
                self.persist(img, key: key)
                DispatchQueue.main.async { boxed.fn(img) }
                return
            }
            // 兜底：主线程用 NSWorkspace 取系统图标（资源目录里的图标无法直接读文件）
            DispatchQueue.main.async {
                guard case .app(let path) = request.kind else { boxed.fn(nil); return }
                let workspaceIcon = NSWorkspace.shared.icon(forFile: path)
                guard let img = Self.rasterize(workspaceIcon, pixelSize: request.pixelSize) else {
                    boxed.fn(nil)
                    return
                }
                self.memory.setObject(IconBox(img), forKey: key as NSString)
                self.queue.async { self.persist(img, key: key) }
                boxed.fn(img)
            }
        }
    }

    // MARK: - 生成

    private static func generate(_ request: IconRequest) -> CGImage? {
        switch request.kind {
        case .app(let path):
            guard let url = iconFileURL(bundleURL: URL(fileURLWithPath: path)) else { return nil }
            return downscale(imageSourceAt: url, pixelSize: request.pixelSize)
        case .folder(let childPaths):
            let children = childPaths.prefix(9).compactMap { path -> CGImage? in
                guard let url = iconFileURL(bundleURL: URL(fileURLWithPath: path)) else { return nil }
                return downscale(imageSourceAt: url, pixelSize: 64)
            }
            return synthesizeFolderIcon(children: children, pixelSize: request.pixelSize)
        case .unknown:
            return nil
        }
    }

    /// 从 bundle 的 Info.plist 定位 icns
    private static func iconFileURL(bundleURL: URL) -> URL? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }

        if let name = (dict["CFBundleIconFile"] as? String) ?? (dict["CFBundleIconName"] as? String), !name.isEmpty {
            var candidate = bundleURL.appendingPathComponent("Contents/Resources/\(name)")
            if candidate.pathExtension.isEmpty { candidate.appendPathExtension("icns") }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        if let files = try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) {
            if let icns = files.first(where: { $0.pathExtension == "icns" }) { return icns }
        }
        return nil
    }

    private static func imageSourceAt(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    private static func downscale(imageSourceAt url: URL, pixelSize: Int) -> CGImage? {
        guard let src = imageSourceAt(url) else { return nil }
        let count = CGImageSourceGetCount(src)
        var best: CGImage?
        var bestWidth = 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, pixelSize)
        ]
        for i in 0..<count {
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, i, options as CFDictionary) else { continue }
            if thumb.width > bestWidth {
                bestWidth = thumb.width
                best = thumb
            }
        }
        if let best, best.width >= pixelSize || best.height >= pixelSize { return best }
        // 缩略图不足目标尺寸时，直接取最大原图再缩放
        var original: CGImage?
        var ow = 0
        for i in 0..<count {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            if img.width > ow { ow = img.width; original = img }
        }
        guard let original else { return best }
        return rasterize(original, pixelSize: pixelSize)
    }

    static func rasterize(_ image: CGImage, pixelSize: Int) -> CGImage? {
        let size = max(8, pixelSize)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: size,
                                  height: size,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    static func rasterize(_ image: NSImage, pixelSize: Int) -> CGImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return rasterize(cg, pixelSize: pixelSize)
    }

    /// 合成文件夹图标：圆角底板 + 3×3 迷你应用图标（对齐原生 LaunchPad 的文件夹样式）
    private static func synthesizeFolderIcon(children: [CGImage], pixelSize: Int) -> CGImage? {
        let size = max(8, pixelSize)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: size,
                                  height: size,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let inset = CGFloat(size) * 0.075
        let plate = bounds.insetBy(dx: inset, dy: inset)
        let radius = plate.width * 0.235
        let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let graySpace = CGColorSpaceCreateDeviceGray()
        let colors = [CGColor(gray: 0.98, alpha: 0.92), CGColor(gray: 0.80, alpha: 0.92)] as CFArray
        if let gradient = CGGradient(colorsSpace: graySpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: plate.maxY),
                                   end: CGPoint(x: 0, y: plate.minY),
                                   options: [])
        }
        ctx.restoreGState()

        // 3×3 迷你图标
        let grid = plate.insetBy(dx: plate.width * 0.085, dy: plate.width * 0.085)
        let cell = grid.width / 3
        let iconSize = cell * 0.78
        ctx.interpolationQuality = .high
        for (index, child) in children.prefix(9).enumerated() {
            let col = index % 3
            let row = index / 3
            let x = grid.minX + CGFloat(col) * cell + (cell - iconSize) / 2
            let y = grid.maxY - CGFloat(row + 1) * cell + (cell - iconSize) / 2
            ctx.draw(child, in: CGRect(x: x, y: y, width: iconSize, height: iconSize))
        }
        return ctx.makeImage()
    }

    // MARK: - 磁盘缓存

    private func cacheKey(_ request: IconRequest) -> String {
        "\(stableHash(request.key))-\(request.pixelSize)"
    }

    private func diskURL(key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).png")
    }

    private func loadFromDisk(key: String) -> CGImage? {
        let url = diskURL(key: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func persist(_ image: CGImage, key: String) {
        let url = diskURL(key: key)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func stableHash(_ string: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx", hash)
    }
}
