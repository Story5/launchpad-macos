import AppKit
import Foundation

// MARK: - 扫描器（后台线程，返回可跨线程数据）

enum AppScanner {
    static let searchDirectories: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Developer/Applications",
        "~/Applications"
    ]

    static func scan() async -> [AppDraft] {
        await Task.detached(priority: .userInitiated) { produce() }.value
    }

    private static func produce() -> [AppDraft] {
        let fm = FileManager.default
        var drafts: [AppDraft] = []
        var seenBundleIDs = Set<String>()
        var seenPaths = Set<String>()

        for rawDir in searchDirectories {
            let dir = (rawDir as NSString).expandingTildeInPath
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                if entry.hasPrefix(".") { continue }
                let path = (dir as NSString).appendingPathComponent(entry)
                guard !seenPaths.contains(path) else { continue }
                guard let dict = infoDictionary(at: path) else { continue }

                // 跳过插件/辅助型 bundle
                if let type = dict["CFBundlePackageType"] as? String, type != "APPL" {
                    if dict["CFBundleExecutable"] == nil { continue }
                }
                let bundleID = dict["CFBundleIdentifier"] as? String
                if let bundleID, seenBundleIDs.contains(bundleID) { continue }

                let name = (dict["CFBundleDisplayName"] as? String)
                    ?? (dict["CFBundleName"] as? String)
                    ?? (entry as NSString).deletingPathExtension

                seenPaths.insert(path)
                if let bundleID { seenBundleIDs.insert(bundleID) }
                drafts.append(AppDraft(id: bundleID ?? path,
                                       name: name,
                                       path: path,
                                       bundleIdentifier: bundleID))
            }
        }

        drafts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return drafts
    }

    private static func infoDictionary(at path: String) -> [String: Any]? {
        let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plist)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }
}

// MARK: - 布局持久化

struct FolderSnapshot: Codable {
    var name: String
    var items: [String]
}

struct LayoutSnapshot: Codable {
    var version: Int = 1
    var capacity: Int = 35
    var pages: [[String]] = []
    var folders: [String: FolderSnapshot] = [:]
}

// MARK: - 资料库

@MainActor
final class Library {
    private(set) var pages: [[LaunchItem]] = [[]]
    private var registry: [String: LaunchItem] = [:]
    var metrics: GridMetrics = .init()

    private let storeURL: URL
    private var lastSnapshot: LayoutSnapshot?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LaunchPadReplica", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("layout.json")
        lastSnapshot = Self.readSnapshot(url: storeURL)
    }

    // MARK: 载入

    func reload(metrics: GridMetrics) async {
        self.metrics = metrics
        let drafts = await AppScanner.scan()

        // 1. 已保存的文件夹
        var folders: [String: LaunchItem] = [:]
        for (fid, snap) in lastSnapshot?.folders ?? [:] {
            let folder = LaunchItem(id: fid, name: snap.name, bundlePath: nil, bundleIdentifier: nil, isFolder: true)
            folders[fid] = folder
            registry[fid] = folder
        }

        // 2. 应用条目
        var itemsByID: [String: LaunchItem] = [:]
        for draft in drafts {
            let item = LaunchItem(id: draft.id,
                                  name: draft.name,
                                  bundlePath: draft.path,
                                  bundleIdentifier: draft.bundleIdentifier,
                                  isFolder: false)
            itemsByID[draft.id] = item
            registry[draft.id] = item
        }

        // 3. 文件夹子项（只保留仍然存在的）
        for (fid, snap) in lastSnapshot?.folders ?? [:] {
            guard let folder = folders[fid] else { continue }
            folder.children = snap.items.compactMap { itemsByID[$0] }
            for child in folder.children { child.parent = folder }
        }

        // 4. 顶层页：优先使用保存顺序
        var orderedTopLevel: [LaunchItem] = []
        var consumed = Set<String>()
        if let snapshotPages = lastSnapshot?.pages, !snapshotPages.isEmpty {
            for page in snapshotPages {
                for id in page {
                    if let folder = folders[id] {
                        orderedTopLevel.append(folder)
                        consumed.insert(id)
                    } else if let item = itemsByID[id] {
                        orderedTopLevel.append(item)
                        consumed.insert(id)
                    }
                }
            }
        }
        // 5. 新安装的 App 追加到末尾（模拟原生 LaunchPad 的行为）
        let folderChildIDs = Set((lastSnapshot?.folders ?? [:]).values.flatMap { $0.items })
        for draft in drafts where !consumed.contains(draft.id) && !folderChildIDs.contains(draft.id) {
            orderedTopLevel.append(itemsByID[draft.id]!)
        }

        // 容量变化时重新分栏（换显示器/分辨率）
        if let capacity = lastSnapshot?.capacity, capacity != metrics.capacity {
            pages = chunk(orderedTopLevel)
        } else {
            pages = chunk(orderedTopLevel)
        }
        normalize()
    }

    private func chunk(_ items: [LaunchItem]) -> [[LaunchItem]] {
        let capacity = max(1, metrics.capacity)
        guard !items.isEmpty else { return [[]] }
        var result: [[LaunchItem]] = []
        var index = 0
        while index < items.count {
            let end = min(index + capacity, items.count)
            result.append(Array(items[index..<end]))
            index = end
        }
        return result
    }

    private func normalize() {
        if pages.isEmpty { pages = [[]] }
    }

    // MARK: 编辑

    func location(of item: LaunchItem) -> (page: Int, slot: Int)? {
        for (p, page) in pages.enumerated() {
            if let s = page.firstIndex(where: { $0 === item }) { return (p, s) }
        }
        return nil
    }

    func moveItem(_ item: LaunchItem, toPage page: Int, slot: Int) {
        guard let from = location(of: item) else { return }
        pages[from.page].remove(at: from.slot)
        var target = max(0, min(pages.count - 1, page))
        var insertSlot = max(0, min(pages[target].count, slot))
        pages[target].insert(item, at: insertSlot)
        // 溢出：把末尾条目挤到下一页（原生行为）
        while pages[target].count > metrics.capacity {
            let overflow = pages[target].removeLast()
            let next = target + 1
            if next >= pages.count { pages.append([]) }
            pages[next].insert(overflow, at: 0)
            target = next
            insertSlot = 0
        }
        normalize()
        save()
    }

    /// 保证存在目标页（拖拽到边缘时用）
    func ensurePage(_ index: Int) {
        while pages.count <= index { pages.append([]) }
    }

    @discardableResult
    func createFolder(with items: [LaunchItem], at page: Int, slot: Int) -> LaunchItem {
        let fid = "folder-\(UUID().uuidString)"
        let name = Self.folderName(for: items.first)
        let folder = LaunchItem(id: fid, name: name, bundlePath: nil, bundleIdentifier: nil, isFolder: true)
        for child in items {
            if let loc = location(of: child) { pages[loc.page].remove(at: loc.slot) }
            child.parent = folder
            folder.children.append(child)
        }
        registry[fid] = folder
        ensurePage(page)
        let insertSlot = max(0, min(pages[page].count, slot))
        pages[page].insert(folder, at: insertSlot)
        normalize()
        save()
        return folder
    }

    /// 按 id 取回条目（跨线程回调里不能传 LaunchItem 本体，只能传 id 回来查）
    func item(byID id: String) -> LaunchItem? { registry[id] }

    func removeFromPages(_ item: LaunchItem) {
        if let loc = location(of: item) { pages[loc.page].remove(at: loc.slot) }
        normalize()
        save()
    }

    func renameFolder(_ folder: LaunchItem, to name: String) {
        folder.name = name
        save()
    }

    private static func folderName(for item: LaunchItem?) -> String {
        // 用 App 自己声明的分类（LSApplicationCategoryType）命名，
        // 贴近原生 LaunchPad 新建文件夹时的自动命名；取不到就回退到「文件夹」
        if let item, let path = item.bundlePath,
           let category = categoryName(bundlePath: path) { return category }
        return "文件夹"
    }

    private static let categoryNames: [String: String] = [
        "business": "商务", "developer-tools": "开发工具", "education": "教育",
        "entertainment": "娱乐", "finance": "财务", "graphics-and-design": "图形与设计",
        "healthcare-and-fitness": "健康与健身", "lifestyle": "生活", "medical": "医疗",
        "music": "音乐", "news": "新闻", "photography": "摄影", "productivity": "效率",
        "reference": "参考", "social-networking": "社交", "sports": "体育",
        "travel": "旅行", "utilities": "实用工具", "video": "视频", "weather": "天气"
    ]

    private static func categoryName(bundlePath: String) -> String? {
        let plistURL = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let raw = dict["LSApplicationCategoryType"] as? String else { return nil }
        let key = raw.replacingOccurrences(of: "public.app-category.", with: "")
        if key.hasPrefix("games") { return "游戏" }
        return categoryNames[key]
    }

    // MARK: 搜索

    func allTopLevelItems() -> [LaunchItem] {
        pages.flatMap { $0 }
    }

    // MARK: 持久化

    func save() {
        var snapshot = LayoutSnapshot()
        snapshot.capacity = metrics.capacity
        snapshot.pages = pages.map { $0.map { $0.id } }
        var folders: [String: FolderSnapshot] = [:]
        for page in pages {
            for item in page where item.isFolder {
                folders[item.id] = FolderSnapshot(name: item.name, items: item.children.map { $0.id })
            }
        }
        snapshot.folders = folders
        lastSnapshot = snapshot
        let url = storeURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func readSnapshot(url: URL) -> LayoutSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LayoutSnapshot.self, from: data)
    }
}
