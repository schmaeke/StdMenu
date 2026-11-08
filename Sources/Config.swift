import AppKit

/// The look of the menu window.
struct Appearance {
    var themes = (light: Theme(), dark: Theme())
    var font = NSFont.systemFont(ofSize: 15)
    var showsScrollbar = true
    /// How many rows a menu shows at most, unless it asks for another number.
    var lines = 10
}

/// A hotkey and the shell command it runs.
struct Binding {
    let hotkey: Hotkey
    let spec: String
    let command: String
}

/// `~/.config/stdmenu/config`: settings and hotkeys, one `key = value` per line.
struct Config {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/stdmenu")

    var appearance = Appearance()
    var bindings: [Binding] = []
    /// What is wrong with the config and its themes, one `file:line: message` each.
    var problems: [String] = []

    /// Reads the config, or the bundled default if there is none.
    static func load() -> Config {
        let url = directory.appending(path: "config")
        guard let source = FileManager.default.fileExists(atPath: url.path)
            ? url : Bundle.main.url(forResource: "config", withExtension: nil)
        else { return Config() }
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            return Config(problems: ["config: cannot read \(source.path)"])
        }
        return parse(text)
    }

    /// Parses config text, collecting problems instead of stopping at the first one.
    static func parse(_ text: String) -> Config {
        var config = Config()
        var problems: [String] = []
        var themes: (light: String?, dark: String?)
        var family: String?
        var size: CGFloat = 15
        var bound: [Hotkey: Int] = [:]
        for (line, key, value) in entries(text, file: "config", problems: &problems) {
            func report(_ message: String) { problems.append("config:\(line): \(message)") }
            switch key {
            case "theme":
                for part in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if part.hasPrefix("light:") {
                        themes.light = String(part.dropFirst(6))
                    } else if part.hasPrefix("dark:") {
                        themes.dark = String(part.dropFirst(5))
                    } else {
                        themes = (part, part)
                    }
                }
            case "font-family":
                family = value
            case "font-size":
                guard let points = Double(value), (6...72).contains(points) else {
                    report("font-size must be a number from 6 to 72, got '\(value)'")
                    continue
                }
                size = points
            case "lines":
                guard let count = Int(value), Wire.lines.contains(count) else {
                    report("lines must be a number from \(Wire.lines.lowerBound) to \(Wire.lines.upperBound), got '\(value)'")
                    continue
                }
                config.appearance.lines = count
            case "scrollbar":
                switch value {
                case "system": config.appearance.showsScrollbar = true
                case "never": config.appearance.showsScrollbar = false
                default: report("scrollbar must be 'system' or 'never', got '\(value)'")
                }
            default:
                guard let hotkey = Hotkey(key) else {
                    report("'\(key)' is neither a setting nor a hotkey; hotkeys need a modifier, except f1-f12")
                    continue
                }
                let binding = Binding(hotkey: hotkey, spec: key, command: value)
                if let index = bound[hotkey] {
                    report("'\(key)' is bound twice; this line replaces the earlier one")
                    config.bindings[index] = binding
                } else {
                    bound[hotkey] = config.bindings.count
                    config.bindings.append(binding)
                }
            }
        }

        var loaded: [String: Theme] = [:]
        func theme(_ name: String?) -> Theme {
            guard let name else { return Theme() }
            if loaded[name] == nil { loaded[name] = Theme(named: name, problems: &problems) ?? Theme() }
            return loaded[name]!
        }
        config.appearance.themes = (theme(themes.light), theme(themes.dark))
        let font = family.flatMap { namedFont($0, size: size) }
        if let family, font == nil { problems.append("config: font '\(family)' not found") }
        config.appearance.font = font ?? .systemFont(ofSize: size)
        config.problems += problems
        return config
    }

    /// A font by family or PostScript name; `monospace` is the system's monospaced font.
    private static func namedFont(_ name: String, size: CGFloat) -> NSFont? {
        name == "monospace" ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) ?? NSFont(name: name, size: size)
    }
}

/// Splits `key = value` lines, skipping blank lines and `#` comments, and reports malformed ones.
func entries(_ text: String, file: String, problems: inout [String]) -> [(line: Int, key: String, value: String)] {
    var entries: [(line: Int, key: String, value: String)] = []
    for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let equals = line.firstIndex(of: "=") else {
            problems.append("\(file):\(index + 1): expected '<key> = <value>'")
            continue
        }
        entries.append((index + 1, line[..<equals].trimmingCharacters(in: .whitespaces),
                        line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)))
    }
    return entries
}
