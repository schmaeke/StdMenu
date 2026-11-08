import AppKit

/// Runs the agent. Started through a symlink such as `~/.local/bin/stdmenu`, it first re-executes the
/// binary inside the app, where it finds its resources.
@MainActor func runAgent() -> Never {
    if let path = Bundle.main.executablePath, let resolved = realpath(path, nil) {
        defer { free(resolved) }
        if String(cString: resolved) != path {
            execv(resolved, CommandLine.unsafeArgv)
            fail("cannot run \(String(cString: resolved)): \(String(cString: strerror(errno)))")
        }
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let agent = Agent()
    withExtendedLifetime(agent) { app.run() }
    exit(0)
}

/// The resident process: owns the hotkeys and the menu window, and serves client requests.
@MainActor final class Agent {
    /// How long after a menu choice `stdmenu --paste` is accepted.
    private static let pasteWindow = Duration.seconds(5)

    /// Hotkey commands find `stdmenu`, the bundled scripts and `$STDMENU_RESOURCES`.
    private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let resources = Bundle.main.resourcePath ?? ""
        environment["PATH"] = [
            Bundle.main.executableURL?.deletingLastPathComponent().path ?? "",
            resources + "/bin",
            environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "/opt/homebrew/bin:/usr/local/bin",
        ].joined(separator: ":")
        environment["STDMENU_RESOURCES"] = resources
        environment["STDMENU_AGENT"] = nil  // or a plain `stdmenu` in a command would start another agent
        return environment
    }()

    private let menu = Menu()
    private var listener: DispatchSourceRead?
    /// The hotkey that opened the current menu; pressing it again closes the menu.
    private var opener: String?
    /// Counts the menus shown, so that replacing a menu does not forget its successor's opener.
    private var menusShown = 0
    /// When a menu last returned a choice; `--paste` is accepted only shortly after.
    private var lastChoice: ContinuousClock.Instant?

    init() {
        listen()
        reload()
    }

    /// Applies the config and returns its problems, which also go to the log.
    @discardableResult private func reload() -> [String] {
        let config = Config.load()
        menu.appearance = config.appearance
        Hotkeys.removeAll()
        var problems = config.problems
        for binding in config.bindings {
            let registered = Hotkeys.add(binding.hotkey) { [unowned self] in trigger(binding) }
            if !registered { problems.append("config: hotkey '\(binding.spec)' is taken by another application") }
        }
        problems.forEach(log)
        return problems
    }

    private func trigger(_ binding: Binding) {
        if menu.isOpen && opener == binding.spec {
            menu.cancel()
            return
        }
        opener = binding.spec
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", binding.command]
        process.environment = Self.environment
        do { try process.run() } catch { log("cannot run '\(binding.command)': \(error.localizedDescription)") }
    }

    private func listen() {
        let socket = Wire.listen()
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .global())
        source.setEventHandler { @Sendable [unowned self] in  // runs off the main actor
            let client = accept(socket, nil, nil)
            guard client >= 0 else {
                usleep(100_000)  // out of descriptors: let others close instead of spinning
                return
            }
            guard Wire.isSameUser(client) else {
                close(client)
                return
            }
            Wire.setTimeout(client, seconds: 5)
            DispatchQueue.global().async {
                let request = Request(Wire.readAll(client))
                Task { @MainActor in self.handle(request, client: client) }
            }
        }
        source.resume()
        listener = source
    }

    private func handle(_ request: Request, client: Int32) {
        switch request {
        case let .menu(prompt, lines, items):
            menusShown += 1
            let shown = menusShown
            menu.show(items, prompt: prompt, lines: lines) { [unowned self] choice in
                if shown == menusShown { opener = nil }
                if choice != nil { lastChoice = .now }
                Wire.reply(client, choice)
            }
        case let .paste(text):
            Wire.reply(client, paste(text) ? "" : nil)
        case .reload:
            Wire.reply(client, reload().map { $0 + "\n" }.joined())
        case .invalid:
            Wire.reply(client, nil)
        }
    }

    /// Puts a menu choice on the clipboard and, given Accessibility access, presses Cmd-V.
    ///
    /// Only one paste is accepted, and only right after a menu choice, so that other programs cannot
    /// use the agent's Accessibility access to type into the frontmost application.
    private func paste(_ text: String) -> Bool {
        guard let choice = lastChoice, choice.duration(to: .now) < Self.pasteWindow else {
            log("refused to paste: no menu choice in the last few seconds")
            return false
        }
        lastChoice = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Ask clipboard managers not to record it (nspasteboard.org convention).
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            log("grant Accessibility access to paste; the text is on the clipboard")
            return true
        }
        // Give the previously focused window a moment to become key again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Keyboard.press("v", flags: .maskCommand) }
        return true
    }
}
