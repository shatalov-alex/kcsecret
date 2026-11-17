import AppKit
import Foundation
import KCSecretCore
import KCSecretKeychain

enum Commands {
    // MARK: set / get / delete / list

    static func set(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [])
        guard parsed.positional.count == 1 else { throw Failure.usage("usage: kcsecret set NAME") }
        try store(name: parsed.positional[0], settings: settings)
    }

    /// Stores the clipboard (or stdin, when piped) as `name`.
    static func store(name: String, settings: Settings) throws {
        try requireSecretName(name)
        let fromClipboard = isatty(0) != 0
        let raw = fromClipboard
            ? NSPasteboard.general.string(forType: .string)
            : String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        guard let secret = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            throw Failure(fromClipboard ? "the clipboard holds no text: copy the secret first" : "nothing on stdin")
        }
        let store = try settings.openOrCreateStore()
        let replaced = try store.store(secret, as: name)
        var message = "\(replaced ? "replaced" : "stored") \(name) (\(secret.count) characters)"
        if fromClipboard, settings.config.clearClipboard {
            NSPasteboard.general.clearContents()
            message += "; clipboard cleared"
        }
        print(message)
    }

    static func get(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [])
        guard parsed.positional.count == 1 else { throw Failure.usage("usage: kcsecret get NAME") }
        let name = parsed.positional[0]
        try requireSecretName(name)
        let store = try settings.openStore()
        guard store.contains(name) else { throw Failure("no secret named \(name)") }
        try Authentication.require(reason: "read the secret \u{201C}\(name)\u{201D}")
        guard let secret = try store.read(name) else { throw Failure("no secret named \(name)") }
        print(secret)
    }

    static func delete(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [])
        guard !parsed.positional.isEmpty else { throw Failure.usage("usage: kcsecret delete NAME...") }
        let store = try settings.openStore()
        var missing = false
        for name in parsed.positional {
            try requireSecretName(name)
            if try store.delete(name) {
                print("deleted \(name)")
            } else {
                Log.error("no secret named \(name)")
                missing = true
            }
        }
        if missing { throw Failure("", code: 1) }
    }

    static func list(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [.flag("--long", "-l")])
        guard parsed.positional.isEmpty else { throw Failure.usage("usage: kcsecret list [--long]") }
        guard let store = try SecretStore.open(at: settings.keychainPath) else {
            if isatty(1) != 0 { Log.note("no keychain at \(settings.keychainPath)-db yet") }
            return
        }
        let items = try store.items()
        guard parsed.has("--long") else {
            items.forEach { print($0.name) }
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let width = items.map(\.name.count).max() ?? 0
        for item in items {
            let date = item.modified.map(formatter.string(from:)) ?? ""
            print(item.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + Style.stdout.dim(date))
        }
    }

    // MARK: .envrc

    static func add(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [.value("--env", "-e"), environmentOption])
        let environment = try environmentArgument(parsed)
        let name: String
        let variable: String?
        if let env = parsed.values["--env"] {
            guard parsed.positional.count <= 1 else { throw Failure.usage("usage: kcsecret add [NAME] --env VAR") }
            try requireVariableName(env)
            variable = env
            if let explicit = parsed.positional.first {
                name = explicit
            } else {
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                var ctx = context(for: cwd, project: nil, settings: settings)
                ctx.env = environment ?? currentEnvrc(in: cwd).active
                name = try template(nil, settings).render(variable: env, context: ctx)
            }
        } else {
            guard (1...2).contains(parsed.positional.count) else {
                throw Failure.usage("usage: kcsecret add NAME [ENV_VAR]  or  kcsecret add [NAME] --env ENV_VAR")
            }
            name = parsed.positional[0]
            variable = parsed.positional.count == 2 ? parsed.positional[1] : nil
        }
        try requireSecretName(name)
        if let variable { try requireVariableName(variable) }
        try store(name: name, settings: settings)
        if let variable { try link(name: name, variable: variable, environment: environment, settings: settings) }
    }

    static func link(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [environmentOption])
        guard parsed.positional.count == 2 else { throw Failure.usage("usage: kcsecret link NAME ENV_VAR [-E ENVIRONMENT]") }
        let (name, variable) = (parsed.positional[0], parsed.positional[1])
        try requireSecretName(name)
        try requireVariableName(variable)
        if let store = try SecretStore.open(at: settings.keychainPath), !store.contains(name) {
            Log.warn("there is no secret named \(name) yet: store it with kcsecret set \(name)")
        }
        try link(name: name, variable: variable, environment: try environmentArgument(parsed), settings: settings)
    }

    static func link(name: String, variable: String, environment: String?, settings: Settings) throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try updateEnvrc(in: cwd, settings: settings) { envrc in
            let suffix = environment.map { $0 == envrc.active ? "" : " (environment \(Envrc.displayName($0)))" } ?? ""
            switch envrc.link(variable: variable, secret: name, in: environment) {
            case .added: Log.note("\(variable) ← \(name)\(suffix)")
            case .replaced(let old): Log.note("\(variable) ← \(name) (was \(old))\(suffix)")
            case .unchanged: break
            }
            warnAboutOtherAssignments(of: [variable], in: envrc)
        }
    }

    static func unlink(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [environmentOption])
        guard !parsed.positional.isEmpty else { throw Failure.usage("usage: kcsecret unlink ENV_VAR... [-E ENVIRONMENT]") }
        let environment = try environmentArgument(parsed)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard FileManager.default.fileExists(atPath: cwd.appendingPathComponent(".envrc").path) else {
            throw Failure("there is no .envrc here")
        }
        try updateEnvrc(in: cwd, settings: settings) { envrc in
            for variable in parsed.positional {
                let where_ = Envrc.displayName(environment ?? envrc.active)
                if envrc.unlink(variable: variable, in: environment) {
                    Log.note("removed \(variable) from \(where_) (the secret stays in the keychain)")
                } else {
                    Log.warn("kcsecret does not set \(variable) in environment \(where_) of this .envrc")
                }
            }
        }
    }

    /// `kcsecret env VAR=NAME...`: one Touch ID prompt, then `export VAR='secret'` for each.
    /// This is what the `.envrc` block runs.
    static func env(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [])
        guard !parsed.positional.isEmpty else { throw Failure.usage("usage: kcsecret env ENV_VAR=NAME...") }
        let mappings = try parseMappings(parsed.positional)
        if let reason = skipReason(settings: settings) {
            announceSkip(reason, count: mappings.count)
            return
        }
        let (values, complete) = try loadSecrets(mappings, settings: settings)
        print(values.map { "export \($0.variable)=\(Shell.quote($0.value))" }.joined(separator: "\n"))
        if !complete { throw Failure("", code: 1) }
    }

    /// `VAR=NAME` tokens, validated.
    static func parseMappings(_ tokens: [String]) throws -> [EnvrcMapping] {
        try tokens.map { token in
            guard let eq = token.firstIndex(of: "=") else { throw Failure.usage("'\(token)' is not ENV_VAR=NAME") }
            let mapping = EnvrcMapping(variable: String(token[..<eq]), secret: String(token[token.index(after: eq)...]))
            try requireVariableName(mapping.variable)
            try requireSecretName(mapping.secret)
            return mapping
        }
    }

    /// One Touch ID prompt, then every secret that exists. `complete` is false if some were missing.
    static func loadSecrets(_ mappings: [EnvrcMapping], settings: Settings) throws
        -> (values: [(variable: String, value: String)], complete: Bool)
    {
        let store = try settings.openStore()
        let present = mappings.filter { store.contains($0.secret) }
        for missing in mappings where !present.contains(missing) {
            Log.warn("no secret named \(missing.secret), so \(missing.variable) stays unset")
        }
        guard !present.isEmpty else { throw Failure("none of the secrets exist") }
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
        try Authentication.require(
            reason: present.count == 1
                ? "read the secret \u{201C}\(present[0].secret)\u{201D}"
                : "load \(present.count) secrets for \u{201C}\(folder)\u{201D}")
        var values: [(variable: String, value: String)] = []
        for mapping in present {
            guard let secret = try store.read(mapping.secret) else { continue }
            values.append((mapping.variable, secret))
        }
        return (values, present.count == mappings.count)
    }

    // MARK: import

    static func importDotEnv(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [
            .value("--file", "-f"), .flag("--all", "-a"), .value("--template", "-t"), .value("--project", "-p"),
            .flag("--no-envrc"), .flag("--strip"), .flag("--keep"), .flag("--dry-run", "-n"), environmentOption,
        ])
        // A positional argument with a "." or "/" is a file (variable names cannot contain either).
        let files = parsed.positional.filter { $0.contains(".") || $0.contains("/") }
        let keys = parsed.positional.filter { !files.contains($0) }
        guard files.count + (parsed.values["--file"] == nil ? 0 : 1) <= 1 else {
            throw Failure.usage("import one file at a time")
        }
        let file = URL(fileURLWithPath: expandTilde(files.first ?? parsed.values["--file"] ?? ".env")).standardizedFileURL
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Failure("there is no \(displayPath(file)) (pass the file with --file PATH)")
        }
        let text: String
        do { text = try String(contentsOf: file, encoding: .utf8) } catch {
            throw Failure("cannot read \(displayPath(file)): \(error.localizedDescription)")
        }
        let dotenv: DotEnv.Result
        do { dotenv = try DotEnv.parse(text) } catch { throw Failure("\(displayPath(file)): \(error)") }
        for warning in dotenv.warnings { Log.warn("\(displayPath(file)): \(warning) (skipped)") }
        let variables = dotenv.variables
        guard !variables.isEmpty else { throw Failure("\(displayPath(file)) sets no variables") }

        let directory = file.deletingLastPathComponent()
        let nameTemplate = try template(parsed.values["--template"], settings)
        var context = context(for: directory, project: parsed.values["--project"], settings: settings)
        let environment = try environmentArgument(parsed) ?? DotEnv.environmentName(fileName: file.lastPathComponent)
        guard environment.isEmpty || Envrc.isEnvironmentName(environment) else {
            throw Failure.usage("\(file.lastPathComponent) gives the environment '\(environment)': pass a name with -E")
        }
        context.env = environment
        let store = try SecretStore.open(at: settings.keychainPath)
        let strip = parsed.has("--strip") || (settings.config.importStrip && !parsed.has("--keep"))

        struct Candidate {
            let entry: DotEnvEntry
            let name: String
            let exists: Bool
        }
        let candidates = variables.map { entry in
            let name = nameTemplate.render(variable: entry.key, context: context)
            return Candidate(entry: entry, name: name, exists: store?.contains(name) ?? false)
        }
        if let empty = candidates.first(where: { $0.name.isEmpty }) {
            throw Failure("the name template gives \(empty.entry.key) an empty name")
        }

        // Choose: named on the command line, --all, or the picker.
        var chosen: [Candidate]
        if !keys.isEmpty {
            chosen = try keys.map { key in
                guard let c = candidates.first(where: { $0.entry.key == key }) else {
                    throw Failure("\(displayPath(file)) does not set \(key)")
                }
                return c
            }
        } else if parsed.has("--all") {
            chosen = candidates
        } else {
            guard isatty(0) != 0 else {
                throw Failure.usage("stdin is not a terminal: name the variables to import, or pass --all")
            }
            var items = candidates.map { c in
                let preselected: Bool
                switch settings.config.importSelection {
                case .secrets: preselected = SecretHeuristics.looksSecret(c.entry.key)
                case .all: preselected = true
                case .none: preselected = false
                }
                let status = c.entry.value.isEmpty ? "empty, skipped" : (c.exists ? "replaces stored" : "new")
                return Picker.Item(
                    label: c.entry.key,
                    detail: "→ \(c.name)  (\(c.entry.value.count) chars, \(status))",
                    selected: preselected && !c.entry.value.isEmpty)
            }
            guard try Picker.run(title: "Move which variables from \(displayPath(file)) into the keychain?", items: &items) else {
                throw Failure("cancelled", code: 130)
            }
            chosen = zip(candidates, items).filter { $0.1.selected }.map(\.0)
        }

        let empty = chosen.filter { $0.entry.value.isEmpty }
        for c in empty { Log.warn("\(c.entry.key) is empty (skipped)") }
        chosen.removeAll { $0.entry.value.isEmpty }
        let duplicates = Dictionary(grouping: chosen, by: \.name).filter { $0.value.count > 1 }
        if let (name, group) = duplicates.first {
            throw Failure(
                "\(group.map(\.entry.key).joined(separator: " and ")) would both be stored as \(name): "
                    + "use a template with {var}, {var_lower} or {var_kebab}")
        }
        guard !chosen.isEmpty else {
            Log.note("nothing selected")
            return
        }
        // Without {env} in the template, two environments get the same names, and storing one
        // would overwrite the other's secret.
        let existing = currentEnvrc(in: directory)
        for c in chosen {
            for other in existing.environments where other != environment {
                if existing.mappings(in: other).contains(where: { $0.secret == c.name }) {
                    throw Failure(
                        "\(c.name) is what environment \(Envrc.displayName(other)) uses for \(c.entry.key); storing "
                            + "\(Envrc.displayName(environment))'s value under the same name would replace it. "
                            + "Put {env} in the name template (e.g. \"\(nameTemplate.template.contains("{env}") ? nameTemplate.template : suggestEnv(nameTemplate.template))\") or pass -t")
                }
            }
        }

        let style = Style.stdout
        let width = chosen.map(\.entry.key.count).max() ?? 0
        if parsed.has("--dry-run") {
            print(style.bold("Would store \(chosen.count) secret(s) in \(displayPath(URL(fileURLWithPath: settings.keychainPath)))-db:"))
            for c in chosen {
                let key = c.entry.key.padding(toLength: width, withPad: " ", startingAt: 0)
                print("  \(key)  → \(c.name)  " + style.dim(c.exists ? "(replaces stored)" : "(new)"))
            }
            if !parsed.has("--no-envrc") {
                print("and map them in environment \(Envrc.displayName(environment)) of \(displayPath(directory.appendingPathComponent(".envrc")))")
            }
            if strip { print("and remove them from \(displayPath(file))") }
            return
        }

        let target = try store ?? settings.openOrCreateStore()
        for c in chosen {
            let replaced = try target.store(c.entry.value, as: c.name)
            let key = c.entry.key.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(style.green("✓")) \(key)  → \(c.name)" + style.dim(replaced ? "  (replaced)" : ""))
        }

        if !parsed.has("--no-envrc") {
            try updateEnvrc(in: directory, settings: settings) { envrc in
                // The first environment a project gets is the one direnv loads.
                if envrc.environments.isEmpty { envrc.use(environment) }
                for c in chosen {
                    if case .replaced(let old) = envrc.link(variable: c.entry.key, secret: c.name, in: environment) {
                        Log.warn("\(c.entry.key) in environment \(Envrc.displayName(environment)) now loads \(c.name) instead of \(old)")
                    }
                }
                if environment != envrc.active {
                    Log.note("mapped in environment \(Envrc.displayName(environment)); direnv loads \(Envrc.displayName(envrc.active)) "
                        + "(kcsecret use \(Envrc.displayName(environment)) to switch)")
                }
                warnAboutOtherAssignments(of: chosen.map(\.entry.key), in: envrc)
            }
        }

        if strip {
            let stripped = try DotEnv.removing(keys: Set(chosen.map(\.entry.key)), from: text)
            try writeInPlace(stripped, to: file)
            Log.note("removed \(chosen.count) variable(s) from \(displayPath(file))")
        } else {
            Log.note(
                Style.stderr.dim(
                    "The values are still in \(displayPath(file)). Remove them by hand, or import with --strip."))
        }
    }

    // MARK: name

    /// `kcsecret name ENV_VAR... [-t TEMPLATE] [-p PROJECT] [-C DIR]`: preview the names a template
    /// gives, without touching the keychain.
    static func name(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [
            .value("--template", "-t"), .value("--project", "-p"), .value("--dir", "-C"), .value("--file", "-f"),
        ])
        guard !parsed.positional.isEmpty else {
            throw Failure.usage("usage: kcsecret name ENV_VAR... [-t TEMPLATE] [-p PROJECT] [-C DIR]")
        }
        let dir = URL(fileURLWithPath: expandTilde(parsed.values["--dir"] ?? FileManager.default.currentDirectoryPath))
        let nameTemplate = try template(parsed.values["--template"], settings)
        var ctx = context(for: dir, project: parsed.values["--project"], settings: settings)
        if let file = parsed.values["--file"] { ctx.env = DotEnv.environmentName(fileName: (file as NSString).lastPathComponent) }
        Log.note(Style.stderr.dim("template \"\(nameTemplate.template)\" in \(displayPath(dir)): {project} = \(ctx.project), {path} = \(ctx.path), {env} = \(ctx.env)"))
        for variable in parsed.positional {
            try requireVariableName(variable)
            print(nameTemplate.render(variable: variable, context: ctx))
        }
    }

    // MARK: config

    static func config(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [.flag("--init"), .flag("--path"), .flag("--force")])
        if parsed.has("--path") {
            print(settings.configPath)
            return
        }
        if parsed.has("--init") {
            if settings.configExists, !parsed.has("--force") {
                throw Failure("\(settings.configPath) already exists (add --force to overwrite it)")
            }
            let url = URL(fileURLWithPath: settings.configPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Config.template.write(to: url, atomically: true, encoding: .utf8)
            print("wrote \(displayPath(url))")
            return
        }
        let c = settings.config
        let style = Style.stdout
        print(style.dim("# \(settings.configPath)\(settings.configExists ? "" : " (not created; kcsecret config --init)")"))
        let rows: [(String, String, String?)] = [
            ("keychain", "\"\(c.keychain)\"", settings.keychainFromEnvironment ? "KCSECRET_KEYCHAIN overrides it: \(settings.keychainPath)" : nil),
            ("name_template", "\"\(c.nameTemplate)\"", nil),
            ("projects_root", "\"\(c.projectsRoot)\"", nil),
            ("envrc_command", "\"\(c.envrcCommand)\"", c.envrcCommand.isEmpty ? "uses \(settings.envrcCommand)" : nil),
            ("clear_clipboard", "\(c.clearClipboard)", nil),
            ("direnv_allow", "\(c.direnvAllow)", nil),
            ("git_exclude", "\(c.gitExclude)", nil),
            ("import_selection", "\"\(c.importSelection.rawValue)\"", nil),
            ("import_strip", "\(c.importStrip)", nil),
        ]
        for (key, value, note) in rows {
            print("\(key) = \(value)" + (note.map { style.dim("  # \($0)") } ?? ""))
        }
    }

    // MARK: helpers

    static func template(_ override: String?, _ settings: Settings) throws -> NameTemplate {
        do { return try NameTemplate(override ?? settings.config.nameTemplate) } catch { throw Failure.usage("\(error)") }
    }

    static func context(for directory: URL, project: String?, settings: Settings) -> NameTemplate.Context {
        let root = projectDirectory(for: directory)
        let name = project ?? root.lastPathComponent
        return NameTemplate.Context(
            project: name,
            path: relativePath(of: root, under: settings.config.projectsRoot) ?? name,
            folder: directory.standardizedFileURL.lastPathComponent,
            user: NSUserName())
    }

    static let environmentOption = Option.value("--environment", "-E")

    /// The template with `{env}` before its variable placeholder: `{path}-{var_lower}` →
    /// `{path}-{env}-{var_lower}`.
    static func suggestEnv(_ template: String) -> String {
        guard let r = template.range(of: "{var") else { return "{env}-" + template }
        let before = template[..<r.lowerBound]
        let separator = before.last.map { "-._".contains($0) ? String($0) : "-" } ?? "-"
        return before + "{env}" + separator + template[r.lowerBound...]
    }

    /// The `-E ENVIRONMENT` value, validated; "default" becomes "".
    static func environmentArgument(_ parsed: Arguments) throws -> String? {
        guard let raw = parsed.values["--environment"] else { return nil }
        guard Envrc.isEnvironmentName(raw) else {
            throw Failure.usage("'\(raw)' is not a valid environment name: use letters, digits, '.', '_' and '-'")
        }
        return Envrc.normalize(raw)
    }

    /// The `.envrc` in `directory`, parsed (empty if there is none).
    static func currentEnvrc(in directory: URL) -> Envrc {
        Envrc(text: (try? String(contentsOf: directory.appendingPathComponent(".envrc"), encoding: .utf8)) ?? "")
    }

    static func warnAboutOtherAssignments(of variables: [String], in envrc: Envrc) {
        for variable in variables where !envrc.otherAssignments(of: variable).isEmpty {
            Log.warn(".envrc also sets \(variable) outside the kcsecret block; the later line wins")
        }
    }
}
