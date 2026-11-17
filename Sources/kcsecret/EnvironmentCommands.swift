import Foundation
import KCSecretCore
import KCSecretKeychain

/// `use` and `export`: a project's environments (default, prod, staging…), which one direnv loads,
/// and writing one out as a `.env` file for tools that want a file, such as Docker.
extension Commands {
    // MARK: use

    /// `kcsecret use [ENVIRONMENT]`: make ENVIRONMENT the one direnv loads. Without it, a picker
    /// (on a terminal) or the list of environments.
    static func use(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [])
        guard parsed.positional.count <= 1 else { throw Failure.usage("usage: kcsecret use [ENVIRONMENT]") }
        let (file, envrc) = try projectEnvrc()
        let directory = file.deletingLastPathComponent()

        let target: String
        if let raw = parsed.positional.first {
            guard Envrc.isEnvironmentName(raw) else { throw Failure.usage("'\(raw)' is not a valid environment name") }
            target = Envrc.normalize(raw)
        } else if isatty(0) != 0, isatty(2) != 0 {
            guard let chosen = try chooseEnvironment(envrc, title: "Which environment should direnv load in \(displayPath(directory))?")
            else { throw Failure("cancelled", code: 130) }
            target = chosen
        } else {
            for env in envrc.environments {
                print((env == envrc.active ? "* " : "  ") + Envrc.displayName(env) + Style.stdout.dim("  (\(envrc.mappings(in: env).count) variable(s))"))
            }
            return
        }

        guard envrc.environments.contains(target) else {
            throw Failure("\(displayPath(file)) has no environment \(Envrc.displayName(target)); "
                + "it has \(envrc.environments.map(Envrc.displayName).joined(separator: ", "))")
        }
        guard target != envrc.active else {
            Log.note("direnv already loads \(Envrc.displayName(target))")
            return
        }
        try updateEnvrc(in: directory, settings: settings) { $0.use(target) }
        Log.note("direnv now loads \(Envrc.displayName(target)) (\(envrc.mappings(in: target).count) variable(s))")
    }

    // MARK: export

    /// `kcsecret export [-E ENVIRONMENT] [ENV_VAR...]`: one Touch ID prompt, then the environment's
    /// secrets and the `.envrc`'s plain variables as a `.env` file (`.env.prod` for prod).
    static func export(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [
            environmentOption, .value("--output", "-o"), .flag("--all", "-a"), .flag("--secrets-only"), .flag("--force"),
        ])
        let (file, envrc) = try projectEnvrc()
        let directory = file.deletingLastPathComponent()
        let interactive = isatty(0) != 0 && isatty(2) != 0

        // Which environment.
        let environment: String
        if let explicit = try environmentArgument(parsed) {
            guard envrc.environments.contains(explicit) else {
                throw Failure("\(displayPath(file)) has no environment \(Envrc.displayName(explicit)); "
                    + "it has \(envrc.environments.map(Envrc.displayName).joined(separator: ", "))")
            }
            environment = explicit
        } else if envrc.environments.count == 1 {
            environment = envrc.environments[0]
        } else if interactive {
            guard let chosen = try chooseEnvironment(envrc, title: "Export which environment of \(displayPath(directory))?")
            else { throw Failure("cancelled", code: 130) }
            environment = chosen
        } else {
            throw Failure.usage("\(displayPath(file)) has several environments ("
                + envrc.environments.map(Envrc.displayName).joined(separator: ", ") + "): pick one with -E")
        }

        // Which variables: the secrets, then the plain ones the secrets do not override.
        struct Candidate {
            let variable: String
            let secret: String?  // nil for a plain variable
            let value: String?
        }
        let secrets = envrc.mappings(in: environment)
        let plain = envrc.plainVariables()
        var candidates = secrets.map { Candidate(variable: $0.variable, secret: $0.secret, value: nil) }
        if !parsed.has("--secrets-only") {
            for entry in plain.variables where !secrets.contains(where: { $0.variable == entry.key }) {
                candidates.append(Candidate(variable: entry.key, secret: nil, value: entry.value))
            }
            for name in plain.skipped {
                Log.warn("\(name) in .envrc needs the shell to work out its value (skipped)")
            }
        }

        var chosen: [Candidate]
        if !parsed.positional.isEmpty {
            chosen = try parsed.positional.map { variable in
                guard let c = candidates.first(where: { $0.variable == variable }) else {
                    throw Failure("environment \(Envrc.displayName(environment)) of \(displayPath(file)) does not set \(variable)")
                }
                return c
            }
        } else if parsed.has("--all") || !interactive {
            chosen = candidates
        } else {
            var items = candidates.map { c in
                Picker.Item(label: c.variable, detail: c.secret.map { "← \($0)  (keychain)" } ?? "plain, from .envrc", selected: true)
            }
            guard try Picker.run(
                title: "Export which variables of \(Envrc.displayName(environment))? (secrets end up in plain text)", items: &items)
            else { throw Failure("cancelled", code: 130) }
            chosen = zip(candidates, items).filter { $0.1.selected }.map(\.0)
        }
        guard !chosen.isEmpty else {
            Log.note("nothing selected")
            return
        }

        // Where to: decide before asking for Touch ID.
        let output = parsed.values["--output"]
        let target: URL? = output == "-" ? nil : output.map { URL(fileURLWithPath: expandTilde($0)).standardizedFileURL }
            ?? directory.appendingPathComponent(environment.isEmpty ? ".env" : ".env.\(environment)")
        if let target, FileManager.default.fileExists(atPath: target.path), !parsed.has("--force") {
            guard interactive else { throw Failure("\(displayPath(target)) exists: pass --force to overwrite it, or -o FILE") }
            guard confirm("\(displayPath(target)) exists. Overwrite it?") else { throw Failure("cancelled", code: 130) }
        }

        // Read the secrets (one Touch ID prompt) and refuse to write a partial file.
        let wanted = chosen.compactMap { c in c.secret.map { EnvrcMapping(variable: c.variable, secret: $0) } }
        var values: [String: String] = [:]
        if !wanted.isEmpty {
            let store = try settings.openStore()
            let missing = wanted.filter { !store.contains($0.secret) }
            guard missing.isEmpty else {
                throw Failure("not in the keychain: " + missing.map { "\($0.secret) (\($0.variable))" }.joined(separator: ", ")
                    + "; nothing written")
            }
            let (loaded, complete) = try loadSecrets(wanted, settings: settings)
            guard complete else { throw Failure("some secrets could not be read; nothing written") }
            for (variable, value) in loaded { values[variable] = value }
        }

        let lines = chosen.map { DotEnv.line(key: $0.variable, value: $0.secret == nil ? $0.value! : values[$0.variable]!) }
        guard let target else {
            print(lines.joined(separator: "\n"))
            return
        }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let text = (["# Written by kcsecret export (environment \(Envrc.displayName(environment)), \(stamp)).",
                     "# Secrets in plain text: delete this file when you no longer need it."] + lines)
            .joined(separator: "\n") + "\n"
        try writePrivately(text, to: target)
        let secretCount = wanted.count
        print("wrote \(chosen.count) variable(s) to \(displayPath(target))"
            + (secretCount > 0 ? Style.stdout.dim(" (\(secretCount) secret(s) in plain text, mode 600)") : ""))
        if runProcess(["git", "ls-files", "--error-unmatch", target.lastPathComponent], in: target.deletingLastPathComponent())?.status == 0 {
            Log.warn("git tracks \(displayPath(target)): do not commit it (git rm --cached \(target.lastPathComponent))")
        } else if keepOutOfGit(target) {
            Log.note("kept \(target.lastPathComponent) out of git (.git/info/exclude)")
        }
    }

    // MARK: helpers

    /// The nearest `.envrc` that maps at least one variable.
    static func projectEnvrc() throws -> (URL, Envrc) {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let file = nearestEnvrc(from: cwd) else {
            throw Failure("no .envrc here or in a parent folder: start with kcsecret import or kcsecret add")
        }
        let envrc = Envrc(text: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
        guard !envrc.environments.isEmpty else { throw Failure("kcsecret maps no variables in \(displayPath(file))") }
        return (file, envrc)
    }

    /// A picker over the environments, starting on the active one; nil if cancelled.
    static func chooseEnvironment(_ envrc: Envrc, title: String) throws -> String? {
        let items = envrc.environments.map { env in
            Picker.Item(
                label: Envrc.displayName(env),
                detail: "\(envrc.mappings(in: env).count) variable(s)" + (env == envrc.active ? ", loaded by direnv" : ""),
                selected: env == envrc.active)
        }
        return try Picker.choose(title: title, items: items).map { envrc.environments[$0] }
    }

    /// Asks a yes/no question on the terminal; no is the default.
    static func confirm(_ question: String) -> Bool {
        guard let tty = FileHandle(forUpdatingAtPath: "/dev/tty") else { return false }
        defer { try? tty.close() }
        tty.write(Data("\(question) [y/N] ".utf8))
        var answer = Data()
        while let byte = try? tty.read(upToCount: 1), let b = byte.first, b != 0x0A { answer.append(b) }
        return ["y", "yes"].contains(String(decoding: answer, as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Writes `text` so only the user can read it, even for a moment.
    static func writePrivately(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try writeInPlace(text, to: url)
        } else {
            guard fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw Failure("cannot write \(url.path)")
            }
        }
    }
}
