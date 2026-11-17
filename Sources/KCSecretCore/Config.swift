import Foundation

/// Settings read from `~/.config/kcsecret/config.toml` (a small TOML subset: `key = "string"`,
/// `key = true|false` and `#` comments). Every setting is optional.
public struct Config: Equatable, Sendable {
    /// Which `.env` variables the `import` picker ticks before you choose.
    public enum ImportSelection: String, CaseIterable, Sendable {
        /// Names that look like credentials (`*_KEY`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, …).
        case secrets
        case all
        case none
    }

    /// The keychain file. `KCSECRET_KEYCHAIN` overrides it.
    public var keychain: String = "~/Library/Keychains/kcsecret.keychain"
    /// How `import` and `add --env` name keychain items; see `NameTemplate`.
    public var nameTemplate: String = NameTemplate.defaultTemplate
    /// The folder `{path}` is relative to.
    public var projectsRoot: String = "~"
    /// How `.envrc` runs kcsecret. Empty: the absolute path of the running binary.
    public var envrcCommand: String = ""
    /// Clear the clipboard after `set` stores a secret from it.
    public var clearClipboard: Bool = true
    /// Run `direnv allow` after changing `.envrc`.
    public var direnvAllow: Bool = false
    /// Add `.envrc` to `.git/info/exclude` unless git already ignores it.
    public var gitExclude: Bool = true
    public var importSelection: ImportSelection = .secrets
    /// Remove imported variables from the `.env` file (as `import --strip`).
    public var importStrip: Bool = false
    /// Over SSH nobody can answer Touch ID, so `.envrc` loads nothing instead of waiting.
    public var skipOverSSH: Bool = true

    public init() {}

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    public static let keys: [String] = [
        "keychain", "name_template", "projects_root", "envrc_command", "clear_clipboard", "direnv_allow", "git_exclude",
        "import_selection", "import_strip", "skip_over_ssh",
    ]

    /// Parses the file's text. Unknown keys are returned as warnings rather than errors, so an
    /// older kcsecret still runs with a newer config.
    public static func parse(_ text: String) throws -> (config: Config, warnings: [String]) {
        var config = Config()
        var warnings: [String] = []
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let number = offset + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let eq = line.firstIndex(of: "=") else {
                throw ParseError(line: number, message: "expected key = value")
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            func string() throws -> String {
                guard raw.count >= 2, let q = raw.first, q == "\"" || q == "'", raw.last == q else {
                    throw ParseError(line: number, message: "\(key) must be a quoted string")
                }
                let inner = String(raw.dropFirst().dropLast())
                return q == "'" ? inner : inner.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            func bool() throws -> Bool {
                switch raw {
                case "true": return true
                case "false": return false
                default: throw ParseError(line: number, message: "\(key) must be true or false")
                }
            }
            switch key {
            case "keychain": config.keychain = try string()
            case "name_template":
                config.nameTemplate = try string()
                do { _ = try NameTemplate(config.nameTemplate) } catch {
                    throw ParseError(line: number, message: "\(error)")
                }
            case "projects_root": config.projectsRoot = try string()
            case "envrc_command": config.envrcCommand = try string()
            case "clear_clipboard": config.clearClipboard = try bool()
            case "direnv_allow": config.direnvAllow = try bool()
            case "git_exclude": config.gitExclude = try bool()
            case "import_selection":
                let value = try string()
                guard let selection = ImportSelection(rawValue: value) else {
                    throw ParseError(
                        line: number,
                        message: "import_selection must be one of "
                            + ImportSelection.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))
                }
                config.importSelection = selection
            case "import_strip": config.importStrip = try bool()
            case "skip_over_ssh": config.skipOverSSH = try bool()
            default:
                warnings.append("line \(number): unknown setting '\(key)' (ignored)")
            }
        }
        return (config, warnings)
    }

    /// A commented file listing every setting at its default, for `kcsecret config --init`.
    public static let template = """
        # kcsecret configuration. Every setting is optional; the values shown are the defaults.
        # Docs: https://github.com/shatalov-alex/kcsecret#configuration

        # The keychain file that holds the secrets. KCSECRET_KEYCHAIN overrides it.
        # keychain = "~/Library/Keychains/kcsecret.keychain"

        # How `kcsecret import` and `kcsecret add --env VAR` name keychain items.
        # Placeholders: {var} {var_lower} {var_kebab} {project} {path} {env} {folder} {user}
        #   {env} is the environment (prod for .env.prod, empty for .env and default), so each
        #   environment gets its own secrets. Keep it in the template if you use environments.
        #   "{project}-{env}-{var_kebab}"  OPENAI_API_KEY in ~/code/shop  ->  shop-openai-api-key
        #                                  ... from .env.prod             ->  shop-prod-openai-api-key
        #   "{var}"                                                       ->  OPENAI_API_KEY
        #   "{user}.{project}.{env}.{var_lower}"                          ->  alex.shop.openai_api_key
        #   "{path}-{env}-{var_lower}"     with projects_root = "~/Developer":
        #                                  ~/Developer/work/acme/shop  ->  work-acme-shop-openai_api_key
        # name_template = "{project}-{env}-{var_kebab}"

        # The folder {path} is relative to. Projects outside it use their folder name.
        # projects_root = "~"

        # How .envrc runs kcsecret. Empty means the absolute path of the binary that wrote it.
        # Set it to "kcsecret" to rely on PATH (handy with Homebrew).
        # envrc_command = ""

        # Clear the clipboard after `kcsecret set` stores a secret from it.
        # clear_clipboard = true

        # Run `direnv allow` after kcsecret changes an .envrc. Off by default: allowing approves the
        # whole file, including lines kcsecret did not write (say, in a freshly cloned repository),
        # so review it and run `direnv allow` yourself.
        # direnv_allow = false

        # Keep .envrc out of git through .git/info/exclude (unless git already ignores it).
        # git_exclude = true

        # Which variables the `kcsecret import` picker ticks up front:
        # "secrets" (names like *_KEY, *TOKEN*, *SECRET*, *PASSWORD*), "all" or "none".
        # import_selection = "secrets"

        # Remove imported variables from the .env file afterwards (as `kcsecret import --strip`).
        # import_strip = false

        # Over SSH nobody is at the Mac to touch the sensor, so .envrc skips the kcsecret section
        # (and says so) instead of waiting for Touch ID. `kcsecret pause` does the same on demand.
        # skip_over_ssh = true

        """

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        for (i, c) in zip(line.indices, line) {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return String(line[..<i])
            }
        }
        return line
    }
}

/// Guesses whether a `.env` variable holds a credential, from its name alone.
public enum SecretHeuristics {
    private static let markers = [
        "KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "PASSPHRASE", "PWD", "AUTH", "CREDENTIAL",
        "PRIVATE", "SIGNATURE", "SALT", "DSN", "CERT", "SESSION", "COOKIE", "WEBHOOK",
    ]
    private static let urlsWithCredentials = ["DATABASE_URL", "REDIS_URL", "MONGODB_URI", "MONGO_URL", "AMQP_URL"]

    public static func looksSecret(_ variable: String) -> Bool {
        let upper = variable.uppercased()
        if urlsWithCredentials.contains(upper) { return true }
        let words = upper.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." }).map(String.init)
        // Whole words (TOKEN, TOKENS) or glued suffixes (APIKEY, DBPASSWORD), so AUTHOR or KEYBOARD
        // do not count.
        return words.contains { word in
            markers.contains { word == $0 || word == $0 + "S" || word.hasSuffix($0) }
        }
    }
}

public enum Shell {
    /// `value` as one POSIX shell word: bare when that is safe, otherwise in single quotes.
    public static func quote(_ value: String) -> String {
        let safe = value.unicodeScalars.allSatisfy {
            $0.isASCIILetter || $0.isASCIIDigit || "@%+=:,./_-".unicodeScalars.contains($0)
        }
        if safe, !value.isEmpty { return value }
        return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
