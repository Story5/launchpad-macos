import Foundation

/// LaunchPad 中的一个条目：应用或文件夹
final class LaunchItem {
    let id: String
    /// 改名时同步重建搜索索引，否则用新名字搜不到
    var name: String { didSet { if oldValue != name { refreshSearchKeys() } } }
    var bundlePath: String?      // .app 绝对路径；文件夹为 nil
    var bundleIdentifier: String?
    var isFolder: Bool
    var children: [LaunchItem] = []
    weak var parent: LaunchItem?

    /// 抖动（编辑）模式下是否显示左上角的删除按钮。
    /// 原生 LaunchPad 只对 Mac App Store 安装的 App 给删除按钮 ——
    /// 手动拖进 /Applications 的第三方 App 和系统内置 App 都没有（只能自己拖到废纸篓）。
    var canDelete: Bool

    // 搜索索引
    private(set) var searchKeys: [String] = []

    init(id: String, name: String, bundlePath: String?, bundleIdentifier: String?,
         isFolder: Bool, canDelete: Bool? = nil) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.isFolder = isFolder
        self.canDelete = canDelete ?? Self.isRemovable(bundlePath: bundlePath, isFolder: isFolder)
        refreshSearchKeys()
    }

    /// 判定是否「可卸载」：只有带 App Store 收据的 App 才算。
    /// 想放宽成「非系统目录里用户能删的都算」，把这里改成 || isWritableByUser 即可。
    private static func isRemovable(bundlePath: String?, isFolder: Bool) -> Bool {
        guard !isFolder, let path = bundlePath else { return false }
        // App Store 安装 → Contents/_MASReceipt/receipt
        let receipt = (path as NSString).appendingPathComponent("Contents/_MASReceipt/receipt")
        return FileManager.default.fileExists(atPath: receipt)
    }

    func refreshSearchKeys() {
        var keys: [String] = [name.lowercased()]
        // 拼音全拼 + 首字母（中文应用名可搜）
        let cf = NSMutableString(string: name) as CFMutableString
        CFStringTransform(cf, nil, kCFStringTransformToLatin, false)
        let pinyin = (cf as String).lowercased()
        keys.append(pinyin)
        let initials = pinyin.split(separator: " ").compactMap { $0.first }.map(String.init).joined()
        if !initials.isEmpty { keys.append(initials) }
        // 英文单词首字母（Xcode → xc）
        let words = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let abbr = words.compactMap { $0.first }.map(String.init).joined().lowercased()
        if abbr.count > 1 { keys.append(abbr) }
        // 注意：不要把 bundle id（com.xxx）纳入搜索键，否则 "co" 会命中所有应用
        searchKeys = Array(Set(keys))
    }

    func matches(query: String) -> Bool {
        if query.isEmpty { return true }
        let q = query.lowercased()
        return searchKeys.contains { $0.contains(q) }
    }

    /// 文件夹图标内容（用于生成预览缩略图）
    var childBundlePaths: [String] {
        children.compactMap { $0.bundlePath }
    }

    var iconVersion: String {
        if isFolder { return "folder:\(id):\(children.map { $0.id }.joined(separator: ","))" }
        return bundlePath ?? id
    }
}

extension LaunchItem: Hashable {
    static func == (lhs: LaunchItem, rhs: LaunchItem) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

// MARK: - 扫描阶段产生的可跨线程数据结构

struct AppDraft: Sendable {
    let id: String
    let name: String
    let path: String
    let bundleIdentifier: String?
}
