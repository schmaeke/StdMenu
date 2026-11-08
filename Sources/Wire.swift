import Foundation

/// The protocol between clients and the agent over a Unix socket.
///
/// A client sends a header line, then its payload, and closes its write side. The agent answers
/// `ok\n<text>` on success, and closes the connection without a reply when a menu was cancelled or a
/// request refused. Both sides only talk to peers running as the same user.
enum Wire {
    static let ok = Array("ok\n".utf8)
    /// The numbers of rows a menu may ask for.
    static let lines = 1...1000

    /// In the per-user temporary directory, which only this user can enter, whatever `$TMPDIR` says.
    static let path: String = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let directory = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0
            ? buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            : NSTemporaryDirectory()
        return (directory as NSString).appendingPathComponent("stdmenu.sock")
    }()

    /// Connects to the agent, or returns nil if it is not running.
    static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard withAddress({ Darwin.connect(fd, $0, $1) }) == 0, isSameUser(fd) else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Creates the listening socket, replacing a stale one. Exits if another agent is running.
    static func listen() -> Int32 {
        if let fd = connect() {
            close(fd)
            log("agent already running")
            exit(0)
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, withAddress({ bind(fd, $0, $1) }) == 0, Darwin.listen(fd, 8) == 0 else {
            fail("cannot listen on \(path): \(String(cString: strerror(errno)))")
        }
        return fd
    }

    static func isSameUser(_ fd: Int32) -> Bool {
        var user = uid_t()
        var group = gid_t()
        return getpeereid(fd, &user, &group) == 0 && user == getuid()
    }

    /// Bounds blocking reads and writes, so that a stuck peer cannot stall the agent.
    static func setTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    static func readAll(_ fd: Int32) -> [UInt8] {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return data }
            data += buffer[..<n]
        }
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            offset += n
        }
    }

    /// Answers a request and closes the connection; nil means cancelled or refused.
    static func reply(_ fd: Int32, _ text: String?) {
        if let text { writeAll(fd, ok + Array(text.utf8)) }
        close(fd)
    }

    private static func withAddress(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { fail("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

/// A request as received by the agent.
enum Request: Sendable {
    /// A menu with at most `lines` visible rows, or the configured number if nil.
    case menu(prompt: String, lines: Int?, items: [Item])
    case paste(String)
    case reload
    case invalid

    init(_ bytes: [UInt8]) {
        let newline = bytes.firstIndex(of: 0x0A) ?? bytes.endIndex
        let header = String(decoding: bytes[..<newline], as: UTF8.self)
            .split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        let body = bytes[min(newline + 1, bytes.endIndex)...]
        switch header.first {
        case "menu" where header.count == 3:  // menu<TAB>lines<TAB>prompt
            let lines = Int(header[1]).flatMap { Wire.lines.contains($0) ? $0 : nil }
            self = .menu(prompt: String(header[2]), lines: lines, items: Item.parse(body))
        case "paste": self = .paste(String(decoding: body, as: UTF8.self))
        case "reload": self = .reload
        default: self = .invalid
        }
    }
}
