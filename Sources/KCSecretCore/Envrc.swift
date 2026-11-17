import Foundation

/// An environment variable that `.envrc` fills from a keychain item.
public struct EnvrcMapping: Equatable, Sendable {
    public var variable: String
    public var secret: String

    public init(variable: String, secret: String) {
        self.variable = variable
        self.secret = secret
    }
}

/// Edits the block kcsecret owns in a direnv `.envrc`:
///
///     # >>> kcsecret >>>
///     # Managed by kcsecret (kcsecret link / unlink / use). One Touch ID prompt loads them all.
///     # kcsecret-use prod
///     eval "$("$HOME/.local/bin/kcsecret" env \
///       OPENAI_API_KEY=shop-prod-openai-api-key \
///       STRIPE_SECRET_KEY=shop-prod-stripe-secret-key)"
///     # Other environments (kcsecret use ENV, export -E ENV, run -E ENV):
///     # kcsecret:default OPENAI_API_KEY=shop-openai-api-key
///     # kcsecret:staging OPENAI_API_KEY=shop-staging-openai-api-key
///     # <<< kcsecret <<<
///
/// A project can have several environments, each its own set of variable → secret mappings.
/// direnv loads the active one (the `eval` line); the others are comments, which only kcsecret
/// reads. The environment named "default" (stored as "") is the one `.env` imports into; it is
/// active unless a `# kcsecret-use NAME` line says otherwise.
///
/// Everything outside the block is kept as is, except lines written by kcsecret 0.x
/// (`export VAR="$(… kcsecret get NAME)"`), which move into the block: one `kcsecret env` call
/// asks for Touch ID once, where one `kcsecret get` per variable asked once each.
public struct Envrc: Sendable {
    public static let beginMarker = "# >>> kcsecret >>>"
    public static let endMarker = "# <<< kcsecret <<<"
    static let useMarker = "# kcsecret-use "
    static let environmentPrefix = "# kcsecret:"

    public enum Change: Equatable, Sendable {
        case added
        case replaced(previousSecret: String)
        case unchanged
    }

    /// The environment direnv loads; "" is "default".
    public private(set) var active = ""
    /// Each environment's mappings, in the order the environments first appeared.
    private var sets: [(name: String, mappings: [EnvrcMapping])] = []
    /// Lines outside the block, without the legacy lines that were moved into it.
    private var lines: [String] = []
    /// Where the block sits (or the first legacy line sat) among `lines`.
    private var blockIndex: Int?
    /// Number of legacy `kcsecret get` lines found, which `render` folds into the block.
    public private(set) var legacyLineCount = 0

    public init(text: String = "") {
        var all = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        var inBlock = false
        var loaded: [EnvrcMapping] = []
        for line in all {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlock {
                if trimmed == Self.endMarker {
                    inBlock = false
                } else if trimmed.hasPrefix(Self.useMarker) {
                    active = Self.normalize(String(trimmed.dropFirst(Self.useMarker.count)))
                } else if trimmed.hasPrefix(Self.environmentPrefix) {
                    let words = trimmed.dropFirst(Self.environmentPrefix.count).split(whereSeparator: { $0 == " " || $0 == "\t" })
                    guard let first = words.first, Self.isEnvironmentName(String(first)) else { continue }
                    for token in words.dropFirst() {
                        if let mapping = Self.mapping(fromToken: String(token)) { set(mapping, in: Self.normalize(String(first))) }
                    }
                } else if !trimmed.hasPrefix("#") {
                    for token in trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                        if let mapping = Self.mapping(fromToken: String(token)) { loaded.append(mapping) }
                    }
                }
            } else if trimmed == Self.beginMarker {
                inBlock = true
                if blockIndex == nil { blockIndex = lines.count }
            } else if let mapping = Self.legacyMapping(from: line) {
                legacyLineCount += 1
                loaded.append(mapping)
                if blockIndex == nil { blockIndex = lines.count }
            } else {
                lines.append(line)
            }
        }
        // The eval line is the active environment, wherever the use marker sat.
        for mapping in loaded { set(mapping, in: active) }
    }

    // MARK: Environments

    /// The display name of an environment: "default" for "".
    public static func displayName(_ environment: String) -> String {
        environment.isEmpty ? "default" : environment
    }

    /// "default" → "", anything else unchanged.
    public static func normalize(_ environment: String) -> String {
        environment == "default" ? "" : environment
    }

    /// Letters, digits, `.`, `_` and `-`, as in `.env.prod` or `.env.eu-west.local`.
    public static func isEnvironmentName(_ name: String) -> Bool {
        SecretName.isValid(name)
    }

    /// The environments that map at least one variable: default first, then in file order.
    public var environments: [String] {
        let names = sets.filter { !$0.mappings.isEmpty }.map(\.name)
        return names.filter(\.isEmpty) + names.filter { !$0.isEmpty }
    }

    /// What direnv loads: the active environment's mappings.
    public var mappings: [EnvrcMapping] { mappings(in: active) }

    public func mappings(in environment: String) -> [EnvrcMapping] {
        sets.first { $0.name == environment }?.mappings ?? []
    }

    /// Makes `environment` the one direnv loads.
    public mutating func use(_ environment: String) {
        active = environment
    }

    // MARK: Mappings

    public func secret(for variable: String, in environment: String? = nil) -> String? {
        mappings(in: environment ?? active).first { $0.variable == variable }?.secret
    }

    /// Maps `variable` to `secret` in `environment` (default: the active one).
    @discardableResult
    public mutating func link(variable: String, secret: String, in environment: String? = nil) -> Change {
        let env = environment ?? active
        let previous = self.secret(for: variable, in: env)
        if previous == secret { return .unchanged }
        set(EnvrcMapping(variable: variable, secret: secret), in: env)
        return previous.map { .replaced(previousSecret: $0) } ?? .added
    }

    /// Removes the variable from `environment` (default: the active one); false if it was not set.
    @discardableResult
    public mutating func unlink(variable: String, in environment: String? = nil) -> Bool {
        let env = environment ?? active
        guard let i = sets.firstIndex(where: { $0.name == env }) else { return false }
        let before = sets[i].mappings.count
        sets[i].mappings.removeAll { $0.variable == variable }
        return sets[i].mappings.count != before
    }

    // MARK: Other lines

    /// Lines outside the block that also assign `variable`, which would fight with the block.
    public func otherAssignments(of variable: String) -> [String] {
        lines.filter { line in
            var s = Substring(line.trimmingCharacters(in: .whitespaces))
            if s.hasPrefix("export ") { s = s.dropFirst(7).drop { $0 == " " } }
            return s.hasPrefix(variable + "=")
        }
    }

    /// Plain `export FOO=bar` (or `FOO=bar`) lines outside the block, with their values. Lines whose
    /// value needs the shell (`$VAR`, `$(…)`, backticks) are in `skipped`, by variable name.
    public func plainVariables() -> (variables: [DotEnvEntry], skipped: [String]) {
        var variables: [DotEnvEntry] = []
        var skipped: [String] = []
        for line in lines {
            var s = Substring(line.trimmingCharacters(in: .whitespaces))
            if s.hasPrefix("export ") { s = s.dropFirst(7).drop { $0 == " " || $0 == "\t" } }
            guard let eq = s.firstIndex(of: "="), DotEnv.isVariableName(String(s[..<eq])) else { continue }
            let name = String(s[..<eq])
            let raw = s[s.index(after: eq)...]
            if !raw.hasPrefix("'"), raw.contains("$") || raw.contains("`") {
                skipped.append(name)
                continue
            }
            guard let parsed = try? DotEnv.parse(line), parsed.entries.count == 1, parsed.warnings.isEmpty else {
                skipped.append(name)
                continue
            }
            variables.removeAll { $0.key == name }
            variables.append(parsed.entries[0])
        }
        return (variables, skipped)
    }

    // MARK: Rendering

    /// The file's new text. `command` is the shell word that runs kcsecret, already quoted.
    public func render(command: String) -> String {
        var out = lines
        let others = environments.filter { $0 != active }.map { (name: $0, mappings: mappings(in: $0)) }
        let loaded = mappings
        if !loaded.isEmpty || !others.isEmpty {
            var block = [
                Self.beginMarker,
                "# Managed by kcsecret (kcsecret link / unlink / use). One Touch ID prompt loads them all.",
            ]
            if !active.isEmpty { block.append(Self.useMarker + active) }
            if !loaded.isEmpty {
                block.append("eval \"$(\(command) env \\")
                for (i, m) in loaded.enumerated() {
                    block.append("  \(m.variable)=\(m.secret)" + (i == loaded.count - 1 ? ")\"" : " \\"))
                }
            }
            if !others.isEmpty {
                block.append("# Other environments (kcsecret use ENV, export -E ENV, run -E ENV):")
                for set in others {
                    for m in set.mappings {
                        block.append(Self.environmentPrefix + Self.displayName(set.name) + " \(m.variable)=\(m.secret)")
                    }
                }
            }
            block.append(Self.endMarker)
            let index = min(blockIndex ?? out.count, out.count)
            if blockIndex == nil, let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                block.insert("", at: 0)
            }
            out.insert(contentsOf: block, at: index)
        }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    // MARK: - Internals

    private mutating func set(_ mapping: EnvrcMapping, in environment: String) {
        guard let s = sets.firstIndex(where: { $0.name == environment }) else {
            sets.append((environment, [mapping]))
            return
        }
        if let i = sets[s].mappings.firstIndex(where: { $0.variable == mapping.variable }) {
            sets[s].mappings[i] = mapping
        } else {
            sets[s].mappings.append(mapping)
        }
    }

    /// `VAR=name`, as written inside the block (possibly followed by `\` or `)"`).
    static func mapping(fromToken token: String) -> EnvrcMapping? {
        var t = Substring(token)
        if t.hasSuffix(")\"") { t = t.dropLast(2) }
        guard let eq = t.firstIndex(of: "=") else { return nil }
        let variable = String(t[..<eq]), secret = String(t[t.index(after: eq)...])
        guard DotEnv.isVariableName(variable), SecretName.isValid(secret) else { return nil }
        return EnvrcMapping(variable: variable, secret: secret)
    }

    private static let legacyPattern = try! Regex(
        #"^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)="\$\(\s*\S*kcsecret\s+get\s+([A-Za-z0-9._-]+)\s*\)"\s*$"#)

    /// `export VAR="$(~/.local/bin/kcsecret get NAME)"`, as written by kcsecret 0.x's `ksecret`.
    static func legacyMapping(from line: String) -> EnvrcMapping? {
        guard let match = try? legacyPattern.wholeMatch(in: line),
              let variable = match[1].substring, let secret = match[2].substring else { return nil }
        return EnvrcMapping(variable: String(variable), secret: String(secret))
    }
}
