import SwiftUI
import AppKit

// MARK: - NSColor hex helper (local to the editor)

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Syntax theme (NSColors, mirrors Palette.syntax)

private struct SQLSyntaxTheme {
    let keyword, function, string, number, boolean, comment, table, identifier, oper, punct: NSColor

    static func of(isDark: Bool) -> SQLSyntaxTheme {
        isDark
        ? SQLSyntaxTheme(keyword: NSColor(rgb: 0xFF7AB2), function: NSColor(rgb: 0x67B7A4), string: NSColor(rgb: 0xFF8170),
                         number: NSColor(rgb: 0xD9C97C), boolean: NSColor(rgb: 0xDABAFF), comment: NSColor(rgb: 0x7F8C98),
                         table: NSColor(rgb: 0xD9A2FF), identifier: NSColor(rgb: 0xF5F5F7), oper: NSColor(rgb: 0x98989D), punct: NSColor(rgb: 0x8E8E93))
        : SQLSyntaxTheme(keyword: NSColor(rgb: 0x9B2393), function: NSColor(rgb: 0x3E8087), string: NSColor(rgb: 0xC41A16),
                         number: NSColor(rgb: 0x1C00CF), boolean: NSColor(rgb: 0x5C2699), comment: NSColor(rgb: 0x5D6C79),
                         table: NSColor(rgb: 0x5C2699), identifier: NSColor(rgb: 0x1D1D1F), oper: NSColor(rgb: 0x6E6E73), punct: NSColor(rgb: 0x8E8E93))
    }
}

// MARK: - Highlighter

private enum SQLHighlighter {
    // Mirrors the DS SqlEditor tokenizer regex.
    static let regex = try! NSRegularExpression(pattern:
        "(--[^\\n]*)|('(?:[^']|'')*')|(\"(?:[^\"]|\"\")*\")|(\\b\\d+\\.?\\d*\\b)|([A-Za-z_][A-Za-z0-9_]*)|([(),.;])|([=<>!+\\-*/%|]+)")

    static func apply(to storage: NSTextStorage, font: NSFont, theme: SQLSyntaxTheme) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: theme.identifier], range: full)
        for m in regex.matches(in: storage.string, range: full) {
            let color: NSColor
            if m.range(at: 1).location != NSNotFound { color = theme.comment }
            else if m.range(at: 2).location != NSNotFound { color = theme.string }
            else if m.range(at: 3).location != NSNotFound { color = theme.table }        // "quoted ident"
            else if m.range(at: 4).location != NSNotFound { color = theme.number }
            else if m.range(at: 5).location != NSNotFound {
                let w = text.substring(with: m.range(at: 5)).lowercased()
                if SQLDialect.booleans.contains(w) { color = theme.boolean }
                else if SQLDialect.keywords.contains(w) { color = theme.keyword }
                else if SQLDialect.functions.contains(w) || followedByParen(text, after: m.range(at: 5)) { color = theme.function }
                else { color = theme.identifier }
            }
            else if m.range(at: 6).location != NSNotFound { color = theme.punct }
            else if m.range(at: 7).location != NSNotFound { color = theme.oper }
            else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: m.range)
        }
        storage.endEditing()
    }

    private static func followedByParen(_ text: NSString, after range: NSRange) -> Bool {
        var i = range.location + range.length
        while i < text.length {
            let c = text.character(at: i)
            if c == 0x20 || c == 0x09 { i += 1; continue }   // skip spaces/tabs
            return c == 0x28 // '('
        }
        return false
    }
}

// MARK: - NSTextView subclass (routes shortcuts + completion keys)

final class SQLTextView: NSTextView {
    weak var coordinator: SQLEditorView.Coordinator?

    override func keyDown(with event: NSEvent) {
        // ⌘↵ (Return or keypad Enter) runs the query.
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            coordinator?.runRequested()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - IDE-style line-number gutter

final class SQLLineNumberGutterView: NSView {
    weak var textView: SQLTextView?
    weak var container: SQLTextEditorContainer?
    override var isFlipped: Bool { true }

    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private var foregroundColor = NSColor.secondaryLabelColor
    private var backgroundColor = NSColor.windowBackgroundColor
    private var separatorColor = NSColor.separatorColor

    init(textView: SQLTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(isDark: Bool) {
        foregroundColor = NSColor(rgb: isDark ? 0x7F8C98 : 0x8E8E93)
        backgroundColor = NSColor(rgb: isDark ? 0x171719 : 0xF3F3F5)
        separatorColor = NSColor(rgb: isDark ? 0x303034 : 0xD8D8DC)
        needsDisplay = true
    }

    func invalidateLineNumbers() {
        guard let textView else { return }
        let lineCount = max(1, textView.string.reduce(1) { $1 == "\n" ? $0 + 1 : $0 })
        let digits = String(lineCount).count
        container?.gutterWidth = max(42, CGFloat(digits) * 7 + 20)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()

        separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height)).fill()

        guard let textView, let layoutManager = textView.layoutManager else { return }

        let text = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: foregroundColor
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right

        var lineNumber = 1
        var characterIndex = 0
        while characterIndex < max(text.length, 1) {
            let lineRange: NSRange
            if text.length == 0 {
                lineRange = NSRange(location: 0, length: 0)
            } else {
                lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            }

            let lineRect: NSRect
            if layoutManager.numberOfGlyphs == 0 {
                lineRect = NSRect(x: 0, y: 0, width: 0, height: textView.font?.pointSize ?? 13)
            } else {
                let glyphIndex = lineRange.location < text.length
                    ? layoutManager.glyphIndexForCharacter(at: lineRange.location)
                    : layoutManager.numberOfGlyphs - 1
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            }

            let yInTextView = lineRect.minY + textView.textContainerOrigin.y
            let y = yInTextView - textView.visibleRect.minY
            if y + lineRect.height >= dirtyRect.minY, y <= dirtyRect.maxY {
                let numberRect = NSRect(x: 5, y: y, width: bounds.width - 13, height: lineRect.height)
                let attrs = attributes.merging([.paragraphStyle: paragraph]) { current, _ in current }
                "\(lineNumber)".draw(in: numberRect, withAttributes: attrs)
            }

            if text.length == 0 { break }
            characterIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        // NSString's line ranges don't emit the empty logical line after a final newline.
        if text.length > 0, text.character(at: text.length - 1) == 0x0A {
            let yInTextView = layoutManager.extraLineFragmentRect.minY + textView.textContainerOrigin.y
            let y = yInTextView - textView.visibleRect.minY
            let numberRect = NSRect(x: 5, y: y, width: bounds.width - 13,
                                    height: layoutManager.extraLineFragmentRect.height)
            let attrs = attributes.merging([.paragraphStyle: paragraph]) { current, _ in current }
            "\(lineNumber)".draw(in: numberRect, withAttributes: attrs)
        }
    }
}

/// Owns the gutter and scroll view as siblings so the gutter is clipped to the
/// editor itself instead of participating in AppKit's window-level ruler layout.
final class SQLTextEditorContainer: NSView {
    let scrollView: NSScrollView
    let gutter: SQLLineNumberGutterView
    var gutterWidth: CGFloat = 42 {
        didSet { if oldValue != gutterWidth { needsLayout = true } }
    }

    init(scrollView: NSScrollView, textView: SQLTextView) {
        self.scrollView = scrollView
        self.gutter = SQLLineNumberGutterView(textView: textView)
        super.init(frame: .zero)
        clipsToBounds = true
        gutter.container = self
        addSubview(gutter)
        addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0,
                                  width: max(0, bounds.width - gutterWidth), height: bounds.height)
    }

    @objc private func scrolled() {
        gutter.needsDisplay = true
    }
}

// MARK: - SwiftUI wrapper

/// A native SQL editor: NSTextView with SQL syntax highlighting and a schema-aware
/// completion popover. The text is a plain `String` binding (the console's buffer),
/// so MCP edits and file persistence read/write it directly.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var isDark: Bool
    var schema: SchemaIndex
    var onRun: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SQLTextEditorContainer {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        // Swap in our subclass configured for code editing.
        let tv = SQLTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.coordinator = context.coordinator
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.usesFindBar = true
        tv.font = context.coordinator.font
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true

        scroll.documentView = tv
        let container = SQLTextEditorContainer(scrollView: scroll, textView: tv)
        context.coordinator.textView = tv
        context.coordinator.lineNumberGutter = container.gutter

        context.coordinator.applyTheme(isDark: isDark)
        context.coordinator.setStringProgrammatically(text)
        return container
    }

    func updateNSView(_ nsView: SQLTextEditorContainer, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.schema = schema
        c.onRun = onRun
        if c.isDark != isDark { c.applyTheme(isDark: isDark) }
        if let tv = c.textView, tv.string != text {
            c.setStringProgrammatically(text)
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: SQLTextView?
        weak var lineNumberGutter: SQLLineNumberGutterView?
        var schema: SchemaIndex
        var onRun: () -> Void
        var isDark: Bool = false
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let completion = CompletionController()
        private var theme = SQLSyntaxTheme.of(isDark: false)
        private var isProgrammatic = false

        init(_ parent: SQLEditorView) {
            self.parent = parent
            self.schema = parent.schema
            self.onRun = parent.onRun
            super.init()
            completion.onSelect = { [weak self] item in self?.accept(item) }
        }

        func applyTheme(isDark: Bool) {
            self.isDark = isDark
            theme = SQLSyntaxTheme.of(isDark: isDark)
            if let tv = textView {
                tv.insertionPointColor = isDark ? NSColor(rgb: 0xF5F5F7) : NSColor(rgb: 0x1D1D1F)
                tv.selectedTextAttributes = [.backgroundColor: (isDark ? NSColor(rgb: 0x0A84FF) : NSColor(rgb: 0x007AFF)).withAlphaComponent(0.28)]
                highlight()
            }
            lineNumberGutter?.applyTheme(isDark: isDark)
        }

        func setStringProgrammatically(_ s: String) {
            guard let tv = textView else { return }
            isProgrammatic = true
            let sel = tv.selectedRange()
            tv.string = s
            let loc = min(sel.location, (s as NSString).length)
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            highlight()
            lineNumberGutter?.invalidateLineNumbers()
            completion.hide()
            isProgrammatic = false
        }

        private func highlight() {
            guard let storage = textView?.textStorage else { return }
            SQLHighlighter.apply(to: storage, font: font, theme: theme)
        }

        func runRequested() { completion.hide(); onRun() }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            highlight()
            lineNumberGutter?.invalidateLineNumbers()
            if !isProgrammatic {
                parent.text = tv.string
                updateCompletions()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Moving the caret away by click dismisses the popover.
            if completion.isVisible, !isProgrammatic { /* keep while typing; hide on explicit nav below */ }
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard completion.isVisible else { return false }
            switch sel {
            case #selector(NSResponder.moveUp(_:)):        completion.moveSelection(-1); return true
            case #selector(NSResponder.moveDown(_:)):      completion.moveSelection(1);  return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                completion.acceptCurrent(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                completion.hide(); return true
            default:
                return false
            }
        }

        // MARK: Completion

        private func updateCompletions() {
            guard let tv = textView else { return }
            let caret = tv.selectedRange().location
            let (items, query, _) = SQLCompletionEngine.compute(text: tv.string, caret: caret, schema: schema)
            guard !items.isEmpty else { completion.hide(); return }
            let rect = tv.firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
            completion.present(items: items, query: query, caretRectOnScreen: rect, isDark: isDark)
        }

        private func accept(_ item: Completion) {
            guard let tv = textView else { return }
            let caret = tv.selectedRange().location
            let (_, _, replace) = SQLCompletionEngine.compute(text: tv.string, caret: caret, schema: schema)
            if tv.shouldChangeText(in: replace, replacementString: item.label) {
                tv.replaceCharacters(in: replace, with: item.label)
                tv.didChangeText()
            }
        }
    }
}
