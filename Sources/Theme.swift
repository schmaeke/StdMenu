import AppKit

/// The colours of the menu window, read from `~/.config/stdmenu/themes/<name>`.
///
/// A theme file holds `key = #rrggbb` lines (or `#rrggbbaa`). Keys it leaves out keep the native
/// look: the translucent system material, system colours and no border.
struct Theme {
    var background: NSColor?
    var foreground = NSColor.labelColor
    /// The characters of an item that match the query, except in the selected item.
    var match = NSColor.controlAccentColor
    var placeholder = NSColor.secondaryLabelColor
    var selectionBackground = NSColor.selectedContentBackgroundColor
    var selectionForeground = NSColor.alternateSelectedControlTextColor
    var cursor = NSColor.textInsertionPointColor
    /// The window outline, and the colour of the divider below the search field.
    var border: NSColor?

    init() {}

    init?(named name: String, problems: inout [String]) {
        let url = Config.directory.appending(path: "themes").appending(path: name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            problems.append("config: theme '\(name)' not found at \(url.path)")
            return nil
        }
        for (line, key, value) in entries(text, file: name, problems: &problems) {
            guard let color = NSColor(hex: value) else {
                problems.append("\(name):\(line): expected a colour like #1c1c1c, got '\(value)'")
                continue
            }
            switch key {
            case "background": background = color
            case "foreground": foreground = color
            case "match-foreground": match = color
            case "placeholder": placeholder = color
            case "selection-background": selectionBackground = color
            case "selection-foreground": selectionForeground = color
            case "cursor-color": cursor = color
            case "border": border = color
            default: problems.append("\(name):\(line): unknown key '\(key)'")
            }
        }
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        let digits = hex.dropFirst()
        guard hex.first == "#", digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit),
              var rgba = UInt32(digits, radix: 16)
        else { return nil }
        if digits.count == 6 { rgba = rgba << 8 | 0xFF }
        let component = { (shift: UInt32) in CGFloat(rgba >> shift & 0xFF) / 255 }
        self.init(srgbRed: component(24), green: component(16), blue: component(8), alpha: component(0))
    }
}
