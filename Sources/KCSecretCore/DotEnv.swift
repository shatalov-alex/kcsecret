import Foundation

/// A variable read from a `.env` file.
public struct DotEnvEntry: Equatable, Sendable {
    public let key: String
    public let value: String
    /// The 1-based lines the assignment spans (more than one for multi-line quoted values).
    public let lines: ClosedRange<Int>

    public init(key: String, value: String, lines: ClosedRange<Int>) {
        self.key = key
        self.value = value
        self.lines = lines
    }
}

public struct DotEnvError: Error, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

/// A parser for the `.env` dialect shared by dotenv, docker compose and direnv's `dotenv`:
///
///     # comment
///     KEY=value                 # unquoted; a ` #` starts a comment
///     export KEY=value          # an optional `export`
///     KEY='literal $value'      # single quotes: taken as is, may span lines
///     KEY="line\nbreak"         # double quotes: \n \r \t \" \\ \$ escapes, may span lines
///
/// `${VAR}` references are kept literally, never expanded.
public enum DotEnv {
    public struct Result: Sendable {
        /// The assignments in file order. A key assigned twice appears twice; see `variables`.
        public var entries: [DotEnvEntry]
        /// Lines that were skipped, with the reason.
        public var warnings: [DotEnvError]

        /// One entry per key, in order of first appearance, holding the last value assigned.
        public var variables: [DotEnvEntry] {
            var order: [String] = []
            var last: [String: DotEnvEntry] = [:]
            for entry in entries {
                if last[entry.key] == nil { order.append(entry.key) }
                last[entry.key] = entry
            }
            return order.map { last[$0]! }
        }
    }

    public static func parse(_ text: String) throws -> Result {
        var scanner = Scanner(text)
        var result = Result(entries: [], warnings: [])
        while !scanner.atEnd {
            scanner.skip { $0 == " " || $0 == "\t" || $0 == "\n" }
            if scanner.atEnd { break }
            let startLine = scanner.line
            if scanner.peek == "#" {
                scanner.skipLine()
                continue
            }
            var key = scanner.take { isNameCharacter($0) }
            if key == "export", scanner.peek == " " || scanner.peek == "\t" {
                scanner.skip { $0 == " " || $0 == "\t" }
                key = scanner.take { isNameCharacter($0) }
            }
            scanner.skip { $0 == " " || $0 == "\t" }
            guard !key.isEmpty, isVariableName(key), scanner.peek == "=" else {
                let reason = key.isEmpty || isVariableName(key)
                    ? "not a KEY=value assignment"
                    : "'\(key)' is not a valid variable name"
                result.warnings.append(DotEnvError(line: startLine, message: reason))
                scanner.skipLine()
                continue
            }
            scanner.advance()  // "="
            scanner.skip { $0 == " " || $0 == "\t" }
            let value: String
            switch scanner.peek {
            case "'", "`":
                let quote = scanner.peek!
                scanner.advance()
                value = scanner.take { $0 != quote }
                guard scanner.peek == quote else {
                    throw DotEnvError(line: startLine, message: "\(key): the \(quote) quote is never closed")
                }
                scanner.advance()
                try finishLine(&scanner, key: key)
            case "\"":
                scanner.advance()
                value = try doubleQuoted(&scanner, key: key, line: startLine)
                try finishLine(&scanner, key: key)
            default:
                var raw = ""
                while let c = scanner.peek, c != "\n" {
                    if c == "#", raw.last == " " || raw.last == "\t" { break }
                    raw.unicodeScalars.append(c)
                    scanner.advance()
                }
                value = raw.trimmingTrailingBlanks()
                scanner.skipLine()
            }
            let endLine = scanner.lastConsumedLine
            result.entries.append(DotEnvEntry(key: key, value: value, lines: startLine...max(startLine, endLine)))
        }
        return result
    }

    /// `text` without the lines that assign any of `keys`. Everything else is kept byte for byte.
    public static func removing(keys: Set<String>, from text: String) throws -> String {
        let doomed = Set(try parse(text).entries.filter { keys.contains($0.key) }.flatMap { Array($0.lines) })
        guard !doomed.isEmpty else { return text }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        for line in doomed.sorted(by: >) where line - 1 < lines.count {
            lines.remove(at: line - 1)
        }
        return lines.joined(separator: "\n")
    }

    /// The environment a file is for, from its name: `.env.prod` → `prod`, `.env.prod.local` →
    /// `prod.local`, `prod.env` → `prod`, `.env` and `.env.local` → empty.
    public static func environmentName(fileName: String) -> String {
        var name = fileName
        if name.hasPrefix(".env.") {
            name.removeFirst(5)
        } else if name.hasSuffix(".env") {
            name.removeLast(4)
        } else if name == ".env" {
            return ""
        }
        return name == "local" ? "" : name
    }

    /// `KEY=value` as a `.env` line that `parse` (and docker compose) read back unchanged. Plain
    /// values stay bare, which `docker run --env-file` (it takes values literally) also reads;
    /// others get single quotes, or double quotes with escapes when they hold `'` or a newline.
    public static func line(key: String, value: String) -> String {
        let bare = value.unicodeScalars.allSatisfy { c in
            c.isASCIILetter || c.isASCIIDigit || "_-.,:/@%+=~^".unicodeScalars.contains(c)
        }
        if bare { return "\(key)=\(value)" }
        if !value.contains("'"), !value.contains("\n"), !value.contains("\r") { return "\(key)='\(value)'" }
        var escaped = ""
        for c in value.unicodeScalars {
            switch c {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "$": escaped += "\\$"
            case "`": escaped += "\\`"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            default: escaped.unicodeScalars.append(c)
            }
        }
        return "\(key)=\"\(escaped)\""
    }

    public static func isVariableName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || first.isASCIILetter else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || $0.isASCIILetter || $0.isASCIIDigit }
    }

    // MARK: - Internals

    private static func isNameCharacter(_ c: Unicode.Scalar) -> Bool {
        c == "_" || c == "." || c == "-" || c.isASCIILetter || c.isASCIIDigit
    }

    private static func doubleQuoted(_ scanner: inout Scanner, key: String, line: Int) throws -> String {
        var value = ""
        while let c = scanner.peek {
            scanner.advance()
            switch c {
            case "\"":
                return value
            case "\\":
                guard let next = scanner.peek else { break }
                scanner.advance()
                switch next {
                case "n": value += "\n"
                case "r": value += "\r"
                case "t": value += "\t"
                case "\"", "\\", "$", "`": value.unicodeScalars.append(next)
                default: value.unicodeScalars.append(contentsOf: ["\\", next])
                }
            default:
                value.unicodeScalars.append(c)
            }
        }
        throw DotEnvError(line: line, message: "\(key): the \" quote is never closed")
    }

    /// After a closing quote, only blanks and a comment may follow on that line.
    private static func finishLine(_ scanner: inout Scanner, key: String) throws {
        scanner.skip { $0 == " " || $0 == "\t" }
        guard scanner.atEnd || scanner.peek == "\n" || scanner.peek == "#" else {
            throw DotEnvError(line: scanner.line, message: "\(key): unexpected text after the closing quote")
        }
        scanner.skipLine()
    }
}

/// A cursor over the unicode scalars of a text, counting lines as it goes.
private struct Scanner {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private(set) var line = 1
    private(set) var lastConsumedLine = 1

    init(_ text: String) {
        scalars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars)
    }

    var atEnd: Bool { index >= scalars.count }
    var peek: Unicode.Scalar? { atEnd ? nil : scalars[index] }

    mutating func advance() {
        guard !atEnd else { return }
        lastConsumedLine = line
        if scalars[index] == "\n" { line += 1 }
        index += 1
    }

    mutating func skip(while predicate: (Unicode.Scalar) -> Bool) {
        while let c = peek, predicate(c) { advance() }
    }

    mutating func take(while predicate: (Unicode.Scalar) -> Bool) -> String {
        var s = ""
        while let c = peek, predicate(c) {
            s.unicodeScalars.append(c)
            advance()
        }
        return s
    }

    /// Consumes the rest of the line, including its newline.
    mutating func skipLine() {
        skip { $0 != "\n" }
        if peek == "\n" {
            lastConsumedLine = line
            line += 1
            index += 1
        }
    }
}

extension Unicode.Scalar {
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

extension String {
    func trimmingTrailingBlanks() -> String {
        var s = self
        while let last = s.unicodeScalars.last, last == " " || last == "\t" { s.unicodeScalars.removeLast() }
        return s
    }
}
