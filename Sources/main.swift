import Foundation

let usage = """
    usage: stdmenu [-0] [-p prompt] [-l lines] [-w width]  pick a line from stdin, print its value
           stdmenu -f query                                print the values of stdin ranked against query
           stdmenu --paste                                 paste stdin into the frontmost application
           stdmenu --reload                                reload the configuration and report problems
           stdmenu agent                                   run the agent (normally started at login)

    Input lines are `label<TAB>value<TAB>icon`; value and icon are optional.
    -0 ends the value with a NUL byte instead of a newline, for `xargs -0`.
    -l shows at most that many rows at a time (default 10, or `lines` in the config).
    -w sets the window width in points (default 640, or `width` in the config).
    """

func log(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("stdmenu: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    log(message)
    exit(2)
}

signal(SIGPIPE, SIG_IGN)

var args = CommandLine.arguments.dropFirst()
switch args.first {
case "agent":
    runAgent()
case nil where ProcessInfo.processInfo.environment["STDMENU_AGENT"] != nil:  // opened as an app
    runAgent()
case "--paste":
    exit(Client.paste())
case "--reload":
    exit(Client.reload())
case "-h", "--help":
    print(usage)
default:
    var prompt = ""
    var lines: Int?
    var width: Int?
    var query: String?
    var terminator: UInt8 = 0x0A
    func value(of option: String) -> String {
        guard let value = args.popFirst() else { fail("\(option) needs a value") }
        return value
    }
    func number(of option: String, in range: ClosedRange<Int>) -> Int {
        guard let number = Int(value(of: option)), range.contains(number) else {
            fail("\(option) needs a number from \(range.lowerBound) to \(range.upperBound)")
        }
        return number
    }
    while let arg = args.popFirst() {
        switch arg {
        case "-0": terminator = 0
        case "-p": prompt = value(of: arg).filter { $0 != "\t" && !$0.isNewline }
        case "-l": lines = number(of: arg, in: Wire.lines)
        case "-w": width = number(of: arg, in: Wire.width)
        case "-f": query = value(of: arg)
        default: fail("unknown option '\(arg)'\n\(usage)")
        }
    }
    if let query { exit(Client.filter(query)) }
    exit(Client.menu(prompt: prompt, lines: lines, width: width, terminator: terminator))
}
