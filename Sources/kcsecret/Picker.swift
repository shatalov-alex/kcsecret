import Darwin
import Foundation

/// A checklist on the terminal: ↑/↓ (or j/k) move, space toggles, a selects all, n none,
/// enter confirms, q or esc cancels. Draws on /dev/tty, so it works while stdout is piped.
/// `choose` is the single-choice version: enter picks the highlighted item.
enum Picker {
    struct Item {
        var label: String
        var detail: String
        var selected: Bool
    }

    /// Returns false if the user cancelled. `items` holds the final selection either way.
    static func run(title: String, items: inout [Item]) throws -> Bool {
        try show(title: title, items: &items, single: false)
    }

    /// The index of the chosen item, or nil if the user cancelled. Starts on the first selected one.
    static func choose(title: String, items: [Item]) throws -> Int? {
        var copy = items
        guard try show(title: title, items: &copy, single: true) else { return nil }
        return copy.firstIndex(where: \.selected)
    }

    private static func show(title: String, items: inout [Item], single: Bool) throws -> Bool {
        let fd = open("/dev/tty", O_RDWR)
        guard fd >= 0 else { throw Failure("no terminal to show the picker on: name the variables or pass --all") }
        defer { close(fd) }

        var original = termios()
        tcgetattr(fd, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        tcsetattr(fd, TCSAFLUSH, &raw)
        let out = TTY(fd: fd)
        out.write("\u{1B}[?25l")  // hide the cursor
        defer {
            tcsetattr(fd, TCSAFLUSH, &original)
            out.write("\u{1B}[?25h")
        }

        let style = Style(enabled: Style.colorAllowed)
        var cursor = single ? (items.firstIndex(where: \.selected) ?? 0) : 0
        var top = 0
        var drawn = 0
        let labelWidth = min(items.map(\.label.count).max() ?? 0, 40)

        func draw() {
            var size = winsize()
            let rows = ioctl(fd, TIOCGWINSZ, &size) == 0 && size.ws_row > 0 ? Int(size.ws_row) : 24
            let cols = ioctl(fd, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
            let visible = max(1, min(items.count, rows - 4))
            if cursor < top { top = cursor }
            if cursor >= top + visible { top = cursor - visible + 1 }

            var lines = [
                style.bold(String(title.prefix(cols - 1))),
                style.dim(String((single ? "↑/↓ move · enter choose · q cancel"
                    : "↑/↓ move · space toggle · a all · n none · enter confirm · q cancel").prefix(cols - 1))),
            ]
            for i in top..<min(items.count, top + visible) {
                let item = items[i]
                let pointer = i == cursor ? style.cyan("›") : " "
                let box = single ? "" : (item.selected ? style.green("◉") : style.dim("○")) + " "
                let label = item.label.count > labelWidth
                    ? String(item.label.prefix(labelWidth - 1)) + "…"
                    : item.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
                let text = String((label + "  " + item.detail).prefix(max(0, cols - 5)))
                let body = i == cursor ? style.bold(text) : (item.selected || single ? text : style.dim(text))
                lines.append("\(pointer) \(box)\(body)")
            }
            let count = items.filter(\.selected).count
            var footer = single ? "" : "\(count) of \(items.count) selected"
            if visible < items.count { footer += (footer.isEmpty ? "" : " · ") + "\(top + 1)–\(top + visible) shown" }
            lines.append(style.dim(footer))

            var frame = drawn > 0 ? "\u{1B}[\(drawn)A" : ""
            for line in lines { frame += "\r" + line + "\u{1B}[K\n" }
            frame += "\u{1B}[J"
            out.write(frame)
            drawn = lines.count
        }

        func clear() {
            if drawn > 0 { out.write("\u{1B}[\(drawn)A\r\u{1B}[J") }
        }

        draw()
        while true {
            guard let key = out.readByte() else { clear(); return false }
            switch key {
            case 0x1B:  // escape: an arrow key, or a lone esc to cancel
                guard out.hasInput(withinMilliseconds: 40), let kind = out.readByte(), kind == 0x5B || kind == 0x4F,
                      let code = out.readByte()
                else { clear(); return false }
                switch code {
                case 0x41: cursor = max(0, cursor - 1)  // up
                case 0x42: cursor = min(items.count - 1, cursor + 1)  // down
                case 0x48: cursor = 0  // home
                case 0x46: cursor = items.count - 1  // end
                default: break
                }
            case UInt8(ascii: "k"): cursor = max(0, cursor - 1)
            case UInt8(ascii: "j"): cursor = min(items.count - 1, cursor + 1)
            case UInt8(ascii: " ") where !single, UInt8(ascii: "x") where !single: items[cursor].selected.toggle()
            case UInt8(ascii: "a") where !single: for i in items.indices { items[i].selected = true }
            case UInt8(ascii: "n") where !single: for i in items.indices { items[i].selected = false }
            case 0x0D, 0x0A:
                if single { for i in items.indices { items[i].selected = i == cursor } }
                clear()
                return true
            case UInt8(ascii: "q"), 0x03, 0x04: clear(); return false
            default: break
            }
            draw()
        }
    }
}

private struct TTY {
    let fd: Int32

    func write(_ s: String) {
        var bytes = Array(s.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeMutableBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n <= 0 { return }
            offset += n
        }
    }

    func readByte() -> UInt8? {
        var byte: UInt8 = 0
        return Darwin.read(fd, &byte, 1) == 1 ? byte : nil
    }

    func hasInput(withinMilliseconds ms: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, ms) > 0
    }
}
