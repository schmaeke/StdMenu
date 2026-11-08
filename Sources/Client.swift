import Foundation

/// The command-line side: forwards requests to the agent. It never touches AppKit, so it starts
/// in a few milliseconds.
enum Client {
    /// Prints the chosen value followed by a newline, or by a NUL byte for `xargs -0`.
    static func menu(prompt: String, lines: Int?, terminator: UInt8) -> Int32 {
        let reply = send("menu\t\(lines.map(String.init) ?? "")\t\(prompt)", stdin())
        guard reply.starts(with: Wire.ok) else { return 1 }
        return write(reply.dropFirst(Wire.ok.count) + [terminator]) ? 0 : 1
    }

    static func paste() -> Int32 {
        var text = stdin()
        if text.last == 0x0A || text.last == 0 { text.removeLast() }
        if text.isEmpty { return 1 }
        return send("paste", text).starts(with: Wire.ok) ? 0 : 1
    }

    /// Reloads the config and prints its problems; fails if there are any.
    static func reload() -> Int32 {
        let reply = send("reload")
        guard reply.starts(with: Wire.ok) else { return 1 }
        let problems = String(decoding: reply.dropFirst(Wire.ok.count), as: UTF8.self)
        problems.split(separator: "\n").forEach { log(String($0)) }
        return problems.isEmpty ? 0 : 1
    }

    /// Ranks stdin locally, without the agent, the way the menu would show it.
    static func filter(_ query: String) -> Int32 {
        let items = Item.parse(stdin())
        let ranked = rank(items, by: Query(query))
        guard !ranked.isEmpty else { return 1 }
        return write(Array(ranked.map { items[$0].value + "\n" }.joined().utf8)) ? 0 : 1
    }

    private static func stdin() -> [UInt8] {
        do {
            return [UInt8](try FileHandle.standardInput.readToEnd() ?? Data())
        } catch {
            fail("cannot read input: \(error.localizedDescription)")
        }
    }

    /// Writes to stdout; false if the reader has gone away.
    private static func write(_ bytes: some Sequence<UInt8>) -> Bool {
        (try? FileHandle.standardOutput.write(contentsOf: Data(bytes))) != nil
    }

    private static func send(_ header: String, _ payload: [UInt8] = []) -> [UInt8] {
        guard let fd = Wire.connect() else {
            fail("agent is not running; open StdMenu.app or run `stdmenu agent`")
        }
        defer { close(fd) }
        Wire.writeAll(fd, Array("\(header)\n".utf8) + payload)
        shutdown(fd, SHUT_WR)
        return Wire.readAll(fd)
    }
}
