import Foundation

/// Where `kcsecret pause` keeps its state: one line per pause, the scope (a project folder, or
/// `*` for every project) and when it ends (Unix seconds; 0 = until `kcsecret resume`).
///
///     *	0
///     /Users/me/Developer/shop	1763300000
///
/// While a pause covers a folder, the `.envrc` there loads no secrets: `kcsecret env` prints why
/// and outputs nothing. Commands typed by hand (`get`, `run`, `export`) are not affected.
public struct Pauses: Equatable, Sendable {
    public static let everywhere = "*"

    public struct Entry: Equatable, Sendable {
        /// A folder path, or `Pauses.everywhere`.
        public var scope: String
        /// nil: until `kcsecret resume`.
        public var until: Date?

        public init(scope: String, until: Date?) {
            self.scope = scope
            self.until = until
        }

        public var isGlobal: Bool { scope == Pauses.everywhere }
    }

    public private(set) var entries: [Entry] = []

    public init(text: String = "") {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let seconds = TimeInterval(parts[1]) else { continue }
            let scope = String(parts[0])
            guard scope == Self.everywhere || scope.hasPrefix("/") else { continue }
            set(Entry(scope: scope, until: seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil))
        }
    }

    public func render() -> String {
        entries.map { "\($0.scope)\t\(Int($0.until?.timeIntervalSince1970 ?? 0))\n" }.joined()
    }

    /// Drops the pauses that have ended. Returns whether any did.
    @discardableResult
    public mutating func prune(now: Date = Date()) -> Bool {
        let before = entries.count
        entries.removeAll { $0.until.map { $0 <= now } ?? false }
        return entries.count != before
    }

    public mutating func pause(_ scope: String, until: Date?) {
        set(Entry(scope: scope, until: until))
    }

    /// Returns false if there was no such pause.
    @discardableResult
    public mutating func resume(_ scope: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.scope == scope }
        return entries.count != before
    }

    public func entry(for scope: String, now: Date = Date()) -> Entry? {
        entries.first { $0.scope == scope && ($0.until.map { $0 > now } ?? true) }
    }

    /// The pause that covers `folder`: its own first, then the global one.
    public func covering(_ folder: String, now: Date = Date()) -> Entry? {
        entry(for: folder, now: now) ?? entry(for: Self.everywhere, now: now)
    }

    private mutating func set(_ entry: Entry) {
        if let i = entries.firstIndex(where: { $0.scope == entry.scope }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
    }

    /// `90s`, `30m`, `2h`, `1d`, or combinations such as `1h30m`. nil if it is not one.
    public static func duration(_ text: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var sawUnit = false
        for c in text.lowercased() {
            if c.isASCII, c.isNumber {
                number.append(c)
                continue
            }
            let unit: TimeInterval
            switch c {
            case "s": unit = 1
            case "m": unit = 60
            case "h": unit = 3600
            case "d": unit = 86400
            default: return nil
            }
            guard let n = Double(number) else { return nil }
            total += n * unit
            number = ""
            sawUnit = true
        }
        guard sawUnit, number.isEmpty, total > 0 else { return nil }
        return total
    }
}

/// Whether this shell came in over SSH, where nobody can touch the Mac's sensor.
public enum Session {
    public static func isSSH(_ environment: [String: String]) -> Bool {
        ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"].contains { !(environment[$0] ?? "").isEmpty }
    }
}
