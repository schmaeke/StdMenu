import AppKit
import UniformTypeIdentifiers

/// The menu window: a search field above a ranked list of items.
///
/// One menu is open at a time; showing another one cancels the previous one in place. The window
/// is a non-activating panel, so the application underneath keeps its focus for pasting.
@MainActor final class Menu: NSObject {
    private static let width: CGFloat = 640
    private static let radius: CGFloat = 16
    private static let padding: CGFloat = 6

    /// The look of the window, applied whenever a menu is shown.
    var appearance = Appearance() {
        didSet { scroll.hasVerticalScroller = appearance.showsScrollbar }
    }

    private let panel = Panel()
    private let material = NSVisualEffectView()
    private let solid = NSView()
    private let outline = Outline()
    private let glass = NSImageView()
    private let field = NSTextField()
    private let divider = NSBox()
    private let scroll = NSScrollView()
    private let table = NSTableView()

    private var theme = Theme()
    private var fieldFont = NSFont.systemFont(ofSize: 22)
    private var items: [Item] = []
    private var query = Query("")
    private var shown: [Int] = []
    private var hasIcons = false
    private var icons: [String: NSImage] = [:]
    /// The screen area the window may use: its top edge is fixed, it grows down to the bottom.
    private var area = NSRect.zero
    private var lines = 0
    /// How many rows fit on screen and are shown now.
    private var rows = 0
    private var completion: ((String?) -> Void)?

    var isOpen: Bool { completion != nil }

    override init() {
        super.init()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = .roundedRect(radius: Self.radius)
        solid.wantsLayer = true
        solid.layer?.cornerRadius = Self.radius
        solid.layer?.masksToBounds = true
        outline.wantsLayer = true
        outline.layer?.cornerRadius = Self.radius
        outline.autoresizingMask = [.width, .height]
        panel.delegate = self

        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        // Not `usesSingleLineMode`: it draws fonts with tall bounding boxes, like Rec Mono, too high.
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self

        divider.boxType = .custom
        divider.borderWidth = 0

        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.refusesFirstResponder = true
        table.addTableColumn(NSTableColumn(identifier: Cell.id))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(click)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
    }

    /// Shows the items, at most `lines` at a time, on the screen under the mouse; `completion` receives
    /// the chosen value or nil.
    func show(_ items: [Item], prompt: String, lines: Int?, completion: @escaping (String?) -> Void) {
        if let previous = self.completion {
            self.completion = nil
            previous(nil)
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            return completion(nil)  // no display attached
        }
        self.items = items
        self.completion = completion
        self.lines = lines ?? appearance.lines
        hasIcons = items.contains { $0.icon != nil }
        if icons.count > 1000 { icons = [:] }

        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        apply(dark ? appearance.themes.dark : appearance.themes.light)
        field.placeholderAttributedString = NSAttributedString(
            string: prompt, attributes: [.foregroundColor: theme.placeholder, .font: fieldFont])
        field.stringValue = ""

        let visible = screen.visibleFrame
        let top = (visible.maxY - visible.height * 0.2).rounded()
        area = NSRect(x: (visible.midX - Self.width / 2).rounded(), y: visible.minY, width: Self.width,
                      height: top - visible.minY)

        refilter()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        panel.undoManager?.removeAllActions()
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = theme.cursor
            editor.allowsUndo = true
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ choice: String?) {
        guard let completion else { return }
        self.completion = nil
        panel.orderOut(nil)
        completion(choice)
    }

    private func apply(_ theme: Theme) {
        self.theme = theme
        let root = theme.background == nil ? material : solid
        if panel.contentView !== root {
            panel.contentView = root
            for view in [glass, field, divider, scroll, outline] { root.addSubview(view) }
        }
        // Match scrollers and other system drawing to a solid background.
        panel.appearance = theme.background.flatMap {
            NSAppearance(named: ($0.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) < 0.5 ? .darkAqua : .aqua)
        }
        solid.layer?.backgroundColor = theme.background?.cgColor
        outline.layer?.borderColor = theme.border?.cgColor
        outline.layer?.borderWidth = theme.border == nil ? 0 : 1
        divider.fillColor = theme.border ?? .separatorColor

        let font = appearance.font
        fieldFont = NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * 22 / 15).rounded()) ?? font
        field.font = fieldFont
        field.textColor = theme.foreground
        glass.symbolConfiguration = .init(pointSize: (fieldFont.pointSize * 0.8).rounded(), weight: .medium)
        glass.contentTintColor = theme.placeholder
        table.rowHeight = (font.pointSize * 2.4).rounded()
    }

    private func refilter() {
        query = Query(field.stringValue)
        shown = rank(items, by: query)
        table.reloadData()
        if !shown.isEmpty { select(0) }
        layout()
    }

    private func layout() {
        let header = (fieldFont.pointSize * 2.55).rounded()
        let fitting = Int((area.height - header - 2 * Self.padding) / table.rowHeight)
        rows = max(0, min(shown.count, lines, fitting))
        let list = rows == 0 ? 0 : CGFloat(rows) * table.rowHeight + 2 * Self.padding
        let width = area.width
        panel.setFrame(NSRect(x: area.minX, y: area.maxY - header - list, width: width, height: header + list),
                       display: true)

        // Centre the icon, and the text's cap height on it, as SF Symbols are designed to sit next to text.
        let center = list + header / 2
        let fieldHeight = field.intrinsicContentSize.height
        let baseline = center - fieldFont.capHeight / 2
        glass.frame = NSRect(x: 18, y: center - 12, width: 24, height: 24)
        field.frame = NSRect(x: 52, y: (baseline - fieldHeight + field.firstBaselineOffsetFromTop).rounded(),
                             width: width - 70, height: fieldHeight)
        divider.frame = NSRect(x: 0, y: list - 1, width: width, height: 1)
        divider.isHidden = rows == 0
        scroll.frame = NSRect(x: 0, y: Self.padding, width: width, height: max(0, list - 2 * Self.padding))
        scroll.isHidden = rows == 0
        table.tableColumns[0].width = scroll.contentSize.width  // leaves room for a permanent scrollbar
        panel.invalidateShadow()
    }

    /// Selects a row and scrolls it into view without animation, so the list keeps up with a held key.
    private func select(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        let rect = table.rect(ofRow: row)
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.y = min(max(origin.y, rect.maxY - clip.bounds.height), rect.minY)
        clip.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        select(max(0, min(shown.count - 1, table.selectedRow + delta)))
    }

    /// Return chooses the selected item; Shift-Return, or Return without matches, the typed text,
    /// kept on one line so that it stays a single value.
    private func accept() {
        let typed = NSApp.currentEvent?.modifierFlags.contains(.shift) == true || shown.isEmpty
        let text = field.stringValue.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if !typed, table.selectedRow >= 0 {
            finish(items[shown[table.selectedRow]].value)
        } else if !text.isEmpty {
            finish(text)
        }
    }

    @objc private func click() {
        guard table.clickedRow >= 0 else { return }
        finish(items[shown[table.clickedRow]].value)
    }

    /// An item's icon: a single character such as an emoji, an image file of up to 10 MB, or else the
    /// Finder icon of a file, which never needs to read the file itself.
    private func icon(_ spec: String) -> NSImage {
        if let icon = icons[spec] { return icon }
        let icon: NSImage
        if spec.count == 1 {
            icon = .glyph(spec)
        } else if let type = UTType(filenameExtension: (spec as NSString).pathExtension), type.conforms(to: .image),
                  let size = try? FileManager.default.attributesOfItem(atPath: spec)[.size] as? Int, size <= 10 << 20,
                  let image = NSImage(contentsOfFile: spec) {
            icon = image
        } else {
            icon = NSWorkspace.shared.icon(forFile: spec)
        }
        icons[spec] = icon
        return icon
    }
}

extension Menu: NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    func windowDidResignKey(_ notification: Notification) { cancel() }

    func controlTextDidChange(_ notification: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-rows)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(rows)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertTabIgnoringFieldEditor(_:)):
            // Complete to the selected label, like dmenu; it then matches exactly and stays selected.
            if table.selectedRow >= 0 {
                field.stringValue = items[shown[table.selectedRow]].label
                refilter()
            }
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            accept()
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        default: return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Cell.id, owner: nil) as? Cell ?? Cell()
        let item = items[shown[row]]
        cell.show(item.label, matches: item.matches(query), font: appearance.font, theme: theme)
        cell.imageView?.image = hasIcons ? item.icon.map(icon) : nil
        cell.showsIcon = hasIcons
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Row.id, owner: nil) as? Row ?? Row()
        view.selection = theme.selectionBackground
        return view
    }
}

private final class Panel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    /// The standard editing shortcuts, which normally come from the Edit menu that the agent lacks.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector? = switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The window border, drawn above the content and transparent to the mouse.
private final class Outline: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws the selection as a rounded rectangle, emphasized even though the list never has focus.
private final class Row: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("row")

    var selection = NSColor.selectedContentBackgroundColor {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.id
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

private final class Cell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("item")

    /// Whether the menu has icons; without them the label starts where the icon would be.
    var showsIcon = true {
        didSet { needsLayout = true }
    }

    private var label = ""
    private var matches: [Range<String.Index>] = []
    private var font = NSFont.systemFont(ofSize: 15)
    private var theme = Theme()

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        addSubview(text)
        textField = text
        imageView = image
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ label: String, matches: [Range<String.Index>], font: NSFont, theme: Theme) {
        (self.label, self.matches, self.font, self.theme) = (label, matches, font, theme)
        render()
    }

    /// Draws the label, with the matched characters highlighted unless the row is selected.
    private func render() {
        let selected = backgroundStyle == .emphasized
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: label, attributes: [
            .font: font, .paragraphStyle: paragraph,
            .foregroundColor: selected ? theme.selectionForeground : theme.foreground,
        ])
        if !selected {
            for range in matches { text.addAttribute(.foregroundColor, value: theme.match, range: NSRange(range, in: label)) }
        }
        textField?.attributedStringValue = text
    }

    /// Places the icon, two thirds of the row high, and the label after it, or alone at the margin.
    override func layout() {
        super.layout()
        guard let textField, let imageView else { return }
        let height = textField.intrinsicContentSize.height
        let size = (bounds.height * 2 / 3).rounded()
        let x = showsIcon ? 18 + size + 10 : 18
        imageView.frame = NSRect(x: 18, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
        imageView.isHidden = !showsIcon
        textField.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - x - 18,
                                 height: height)
    }
}

private extension NSImage {
    /// A character drawn as a 24 pt icon, so that an emoji can stand in for an image.
    static func glyph(_ character: String) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            let text = NSAttributedString(string: character, attributes: [
                .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor,
            ])
            // Centre the ink, measured from the baseline, which is also where drawing starts.
            let ink = text.boundingRect(with: rect.size, options: .usesDeviceMetrics)
            let baseline = NSPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
            text.draw(with: NSRect(origin: baseline, size: rect.size), options: .usesDeviceMetrics)
            return true
        }
    }

    /// A stretchable mask that gives a view rounded corners.
    static func roundedRect(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
