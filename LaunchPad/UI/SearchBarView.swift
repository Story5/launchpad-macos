import AppKit
import QuartzCore

/// 顶部居中的搜索框（毛玻璃 + 放大镜 + 占位符），行为对齐原生：任意字符输入即进入搜索
@MainActor
final class SearchBarView: NSView {
    private let effectView: NSVisualEffectView
    private let textField = NSTextField()
    private let magnifier = NSImageView()
    private let placeholderLayer = CATextLayer()

    var onTextChange: ((String) -> Void)?
    var onCommand: ((Selector) -> Bool)?

    var isSearching: Bool { !textField.stringValue.isEmpty }

    var text: String {
        get { textField.stringValue }
        set {
            isProgrammaticUpdate = true
            textField.stringValue = newValue
            if let editor = textField.currentEditor() as? NSTextView {
                editor.string = newValue
                editor.setSelectedRange(NSRange(location: (newValue as NSString).length, length: 0))
            }
            isProgrammaticUpdate = false
            updatePlaceholder()
            onTextChange?(newValue)
        }
    }

    private var isProgrammaticUpdate = false

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        effectView = NSVisualEffectView(frame: frameRect)
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true

        super.init(frame: frameRect)
        wantsLayer = true

        addSubview(effectView)

        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        addSubview(magnifier)

        textField.isBezeled = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.drawsBackground = false
        textField.textColor = .white
        textField.font = NSFont.systemFont(ofSize: 14)
        textField.focusRingType = .none
        textField.delegate = self
        addSubview(textField)

        // 自绘占位符：原生在聚焦状态下依然显示「搜索」，NSTextField 自带占位符做不到
        placeholderLayer.string = "搜索"
        placeholderLayer.font = NSFont.systemFont(ofSize: 14)
        placeholderLayer.fontSize = 14
        placeholderLayer.foregroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        placeholderLayer.alignmentMode = .left
        placeholderLayer.contentsScale = 2
        placeholderLayer.zPosition = 1
        layer?.addSublayer(placeholderLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        magnifier.frame = CGRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        textField.frame = CGRect(x: 32, y: 2, width: bounds.width - 42, height: bounds.height - 4)
        placeholderLayer.frame = CGRect(x: 33, y: (bounds.height - 18) / 2 - 1, width: bounds.width - 44, height: 18)
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        let empty = textField.stringValue.isEmpty && ((textField.currentEditor() as? NSTextView)?.string.isEmpty ?? true)
        placeholderLayer.opacity = empty ? 1 : 0
    }

    func makeFocused() {
        window?.makeFirstResponder(textField)
        // 让 field editor 与控件内容对齐，避免首次输入时被空串覆盖
        if let editor = textField.currentEditor() as? NSTextView {
            editor.string = textField.stringValue
            editor.setSelectedRange(NSRange(location: (textField.stringValue as NSString).length, length: 0))
        }
    }

    func clear() {
        text = ""
    }

    func setPresented(_ presented: Bool, animated: Bool) {
        let duration = animated ? 0.28 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = presented ? 1 : 0
        }
        alphaValue = presented ? 1 : 0
    }

    func setDimmed(_ dimmed: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            animator().alphaValue = dimmed ? 0.25 : 1
        }
    }
}

extension SearchBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard !isProgrammaticUpdate else { return }
        let value = (textField.currentEditor() as? NSTextView)?.string ?? textField.stringValue
        updatePlaceholder()
        onTextChange?(value)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if let handled = onCommand?(commandSelector), handled { return true }
        return false
    }
}
