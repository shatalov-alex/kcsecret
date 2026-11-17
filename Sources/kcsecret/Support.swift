import Foundation
import KCSecretCore
import KCSecretKeychain

let version = "1.0.0"

// MARK: - Errors and output

/// Ends the command with a message on stderr and an exit code (1 by default, 2 for usage errors).
struct Failure: Error {
    let message: String
    let code: Int32

    init(_ message: String, code: Int32 = 1) {
        self.message = message
        self.code = code
    }

    static func usage(_ message: String) -> Failure { Failure(message, code: 2) }
}

struct Style {
    let enabled: Bool

    static var colorAllowed: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["NO_COLOR"] == nil && env["TERM"] != "dumb"
    }

    static let stdout = Style(enabled: colorAllowed && isatty(1) != 0)
    static let stderr = Style(enabled: colorAllowed && isatty(2) != 0)

    private func wrap(_ s: String, _ code: String) -> String { enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    func bold(_ s: String) -> String { wrap(s, "1") }
    func dim(_ s: String) -> String { wrap(s, "2") }
    func red(_ s: String) -> String { wrap(s, "31") }
    func green(_ s: String) -> String { wrap(s, "32") }
    func yellow(_ s: String) -> String { wrap(s, "33") }
    func cyan(_ s: String) -> String { wrap(s, "36") }
}

enum Log {
    /// stdout is buffered when piped; flush it so messages on the two streams stay in order.
    private static func flush() { fflush(stdout) }

    static func error(_ message: String) {
        flush()
        FileHandle.standardError.write(Data("kcsecret: \(Style.stderr.red("error:")) \(message)\n".utf8))
    }

    static func warn(_ message: String) {
        flush()
        FileHandle.standardError.write(Data("kcsecret: \(Style.stderr.yellow("warning:")) \(message)\n".utf8))
    }

    /// Progress and hints go to stderr, so stdout stays clean for `get`, `env` and `list`.
    static func note(_ message: String) {
        flush()
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

// MARK: - Arguments

struct Option {
    let names: [String]
    let takesValue: Bool
    var key: String { names[0] }

    static func flag(_ names: String...) -> Option { Option(names: names, takesValue: false) }
    static func value(_ names: String...) -> Option { Option(names: names, takesValue: true) }
}

struct Arguments {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: ArraySlice<String>, options: [Option]) throws {
        var rest = args[...]
        while let arg = rest.popFirst() {
            if arg == "--" {
                positional += rest
                break
            }
            guard arg.hasPrefix("-"), arg.count > 1 else {
                positional.append(arg)
                continue
            }
            let (name, inline) = arg.hasPrefix("--") && arg.contains("=")
                ? (String(arg[..<arg.firstIndex(of: "=")!]), String(arg[arg.index(after: arg.firstIndex(of: "=")!)...]))
                : (arg, nil)
            guard let option = options.first(where: { $0.names.contains(name) }) else {
                throw Failure.usage("unknown option \(name) (see kcsecret help)")
            }
            if option.takesValue {
                guard let value = inline ?? rest.popFirst() else { throw Failure.usage("\(name) needs a value") }
                values[option.key] = value
            } else {
                guard inline == nil else { throw Failure.usage("\(name) takes no value") }
                flags.insert(option.key)
            }
        }
    }

    func has(_ key: String) -> Bool { flags.contains(key) }
}

func requireSecretName(_ name: String) throws {
    guard SecretName.isValid(name) else {
        throw Failure.usage("'\(name)' is not a valid name: use letters, digits, '.', '_' and '-'")
    }
}

func requireVariableName(_ name: String) throws {
    guard DotEnv.isVariableName(name) else { throw Failure.usage("'\(name)' is not a valid variable name") }
}

// MARK: - Settings

struct Settings {
    let config: Config
    let configPath: String
    let configExists: Bool
    let keychainPath: String
    let keychainFromEnvironment: Bool
    /// Where `kcsecret pause` keeps its state.
    let pausesPath: String

    static func load() throws -> Settings {
        let env = ProcessInfo.processInfo.environment
        let configPath = env["KCSECRET_CONFIG"].map(expandTilde)
            ?? (env["XDG_CONFIG_HOME"].map(expandTilde) ?? NSHomeDirectory() + "/.config") + "/kcsecret/config.toml"
        var config = Config()
        // KCSECRET_CONFIG=/dev/null (or empty) means: no config file, defaults only.
        let disabled = configPath.isEmpty || configPath == "/dev/null"
        let exists = !disabled && FileManager.default.fileExists(atPath: configPath)
        if exists {
            let text: String
            do { text = try String(contentsOfFile: configPath, encoding: .utf8) } catch {
                throw Failure("cannot read \(configPath): \(error.localizedDescription)")
            }
            do {
                let parsed = try Config.parse(text)
                config = parsed.config
                for warning in parsed.warnings { Log.warn("\(configPath): \(warning)") }
            } catch let error as Config.ParseError {
                throw Failure("\(configPath): \(error)")
            }
        }
        let keychain = env["KCSECRET_KEYCHAIN"].flatMap { $0.isEmpty ? nil : $0 }
        let pauses = env["KCSECRET_PAUSES"].flatMap { $0.isEmpty ? nil : expandTilde($0) }
            ?? (env["XDG_STATE_HOME"].map(expandTilde) ?? NSHomeDirectory() + "/.local/state") + "/kcsecret/paused"
        return Settings(
            config: config, configPath: configPath, configExists: exists,
            keychainPath: SecretStore.normalize(keychain ?? config.keychain),
            keychainFromEnvironment: keychain != nil, pausesPath: pauses)
    }

    /// Opens the keychain, failing with a hint if it does not exist yet.
    func openStore() throws -> SecretStore {
        guard let store = try SecretStore.open(at: keychainPath) else {
            throw Failure("no keychain at \(keychainPath)-db yet: store a secret first (kcsecret set NAME)")
        }
        return store
    }

    func openOrCreateStore() throws -> SecretStore {
        if let store = try SecretStore.open(at: keychainPath) { return store }
        Log.note("Creating the keychain \(keychainPath)-db: macOS will ask you to choose its password.")
        let store = try SecretStore.create(at: keychainPath)
        Log.note("created \(keychainPath)-db")
        return store
    }

    /// The shell word `.envrc` uses to run kcsecret.
    var envrcCommand: String {
        if !config.envrcCommand.isEmpty { return config.envrcCommand }
        let path = executablePath()
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") {
            let rest = String(path.dropFirst(home.count))
            if !rest.contains(where: { "\"$`\\".contains($0) }) { return "\"$HOME\(rest)\"" }
        }
        return Shell.quote(path)
    }
}

func expandTilde(_ path: String) -> String { (path as NSString).expandingTildeInPath }

/// The running binary's path as invoked (not resolving symlinks, so a Homebrew upgrade keeps working).
func executablePath() -> String {
    let arg0 = CommandLine.arguments[0]
    if arg0.contains("/") {
        let absolute = arg0.hasPrefix("/") ? arg0 : FileManager.default.currentDirectoryPath + "/" + arg0
        return (absolute as NSString).standardizingPath
    }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = "\(dir)/\(arg0)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return (candidate as NSString).standardizingPath }
    }
    return Bundle.main.executablePath ?? arg0
}

// MARK: - Processes, git and direnv

@discardableResult
func runProcess(_ arguments: [String], in directory: URL? = nil, captureOutput: Bool = true) -> (status: Int32, output: String)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    let pipe = Pipe()
    if captureOutput {
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
    }
    do { try process.run() } catch { return nil }
    let data = captureOutput ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func commandExists(_ name: String) -> Bool {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
        FileManager.default.isExecutableFile(atPath: "\($0)/\(name)")
    }
}

/// The project a folder belongs to: its git repository's root, else the folder itself.
func projectDirectory(for directory: URL) -> URL {
    var dir = directory.standardizedFileURL
    while dir.path != "/" {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
        dir.deleteLastPathComponent()
    }
    return directory.standardizedFileURL
}

/// The project's path under `root` (`work/acme/shop`), or nil when it is not inside `root`.
func relativePath(of project: URL, under root: String) -> String? {
    let rootPath = URL(fileURLWithPath: expandTilde(root)).resolvingSymlinksInPath().path
    let path = project.resolvingSymlinksInPath().path
    guard path.hasPrefix(rootPath + "/") else { return nil }
    return String(path.dropFirst(rootPath.count + 1))
}

/// Adds the file to the repository's `.git/info/exclude`, unless git ignores it already.
/// Returns whether it added it.
func keepOutOfGit(_ file: URL) -> Bool {
    let dir = file.deletingLastPathComponent()
    guard commandExists("git"),
          let gitPath = runProcess(["git", "rev-parse", "--git-path", "info/exclude"], in: dir), gitPath.status == 0,
          runProcess(["git", "check-ignore", "-q", file.lastPathComponent], in: dir)?.status != 0
    else { return false }
    let raw = gitPath.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let exclude = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : dir.appendingPathComponent(raw)
    try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
    let addition = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + file.lastPathComponent + "\n"
    return (try? (existing + addition).write(to: exclude, atomically: false, encoding: .utf8)) != nil
}

/// Writes text in place, so the file keeps its permissions (a `.env` is often mode 600).
func writeInPlace(_ text: String, to url: URL) throws {
    do { try text.write(to: url, atomically: false, encoding: .utf8) } catch {
        throw Failure("cannot write \(url.path): \(error.localizedDescription)")
    }
}

func displayPath(_ url: URL) -> String {
    let path = url.resolvingSymlinksInPath().path
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
    if path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

// MARK: - .envrc

/// Applies `edit` to the `.envrc` in `directory`, writes it if it changed, keeps it out of git and
/// lets direnv load it, as the settings allow.
func updateEnvrc(in directory: URL, settings: Settings, _ edit: (inout Envrc) throws -> Void) throws {
    let file = directory.appendingPathComponent(".envrc")
    let exists = FileManager.default.fileExists(atPath: file.path)
    let before = exists ? try String(contentsOf: file, encoding: .utf8) : ""
    var envrc = Envrc(text: before)
    try edit(&envrc)
    let after = envrc.render(command: settings.envrcCommand)
    guard after != before else {
        Log.note("\(displayPath(file)) is up to date")
        return
    }
    try writeInPlace(after, to: file)
    if envrc.legacyLineCount > 0 {
        Log.note("moved \(envrc.legacyLineCount) older `kcsecret get` line(s) into the kcsecret block (one Touch ID prompt for all)")
    }
    Log.note("\(exists ? "updated" : "created") \(displayPath(file))")
    if settings.config.gitExclude, keepOutOfGit(file) {
        Log.note("kept .envrc out of git (.git/info/exclude)")
    }
    guard !after.isEmpty else { return }
    guard settings.config.direnvAllow else {
        Log.note(Style.stderr.dim("Review it, then run `direnv allow` to load it."))
        return
    }
    guard commandExists("direnv") else {
        Log.warn("direnv is not installed, so nothing loads .envrc yet: brew install direnv (https://direnv.net)")
        return
    }
    if runProcess(["direnv", "allow", directory.path], captureOutput: false)?.status != 0 {
        Log.warn("`direnv allow` failed: run it yourself in \(displayPath(directory))")
    }
}
