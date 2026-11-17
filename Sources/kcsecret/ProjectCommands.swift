import Foundation
import KCSecretCore
import KCSecretKeychain

/// `run`, `status` and `doctor`: using a project's secrets without exporting them, and checking
/// that everything is set up so reading needs only Touch ID.
extension Commands {
    // MARK: run

    /// `kcsecret run [ENV_VAR=NAME...] -- COMMAND [ARGS...]`: one Touch ID prompt, then COMMAND
    /// runs with the secrets in its environment only. Without mappings, uses the kcsecret block of
    /// the nearest `.envrc`.
    static func run(_ args: ArraySlice<String>, settings: Settings) throws {
        let usage = "usage: kcsecret run [-E ENVIRONMENT] [ENV_VAR=NAME...] -- COMMAND [ARGS...]"
        guard let separator = args.firstIndex(of: "--") else { throw Failure.usage(usage) }
        let command = Array(args[args.index(after: separator)...])
        guard !command.isEmpty else { throw Failure.usage(usage) }

        let parsed = try Arguments(args[..<separator], options: [environmentOption])
        let environment = try environmentArgument(parsed)
        var mappings = try parseMappings(parsed.positional)
        if mappings.isEmpty {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            guard let file = nearestEnvrc(from: cwd), let envrc = try? Envrc(text: String(contentsOf: file, encoding: .utf8)),
                  !envrc.environments.isEmpty
            else {
                throw Failure("no .envrc with kcsecret variables here or above; name them: kcsecret run VAR=NAME -- \(command[0])")
            }
            mappings = envrc.mappings(in: environment ?? envrc.active)
            guard !mappings.isEmpty else {
                throw Failure("\(displayPath(file)) has no environment \(Envrc.displayName(environment ?? envrc.active)); "
                    + "it has \(envrc.environments.map(Envrc.displayName).joined(separator: ", "))")
            }
        } else if environment != nil {
            throw Failure.usage("-E picks mappings from .envrc: pass either -E or ENV_VAR=NAME pairs")
        }

        let (values, _) = try loadSecrets(mappings, settings: settings)
        for (variable, value) in values { setenv(variable, value, 1) }
        fflush(stdout)
        var argv = command.map { strdup($0) } + [nil]
        execvp(command[0], &argv)
        throw Failure("cannot run \(command[0]): \(String(cString: strerror(errno)))", code: 127)
    }

    // MARK: status

    /// What the nearest `.envrc` loads, whether each secret exists and can be read with Touch ID
    /// alone, and whether direnv allows and has loaded the file. Never asks for anything.
    static func status(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [environmentOption])
        guard parsed.positional.isEmpty else { throw Failure.usage("usage: kcsecret status [-E ENVIRONMENT]") }
        let style = Style.stdout
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let file = nearestEnvrc(from: cwd) else {
            print("No .envrc here or in a parent folder. Start with kcsecret import or kcsecret add.")
            return
        }
        let envrc = Envrc(text: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
        let directory = file.deletingLastPathComponent()

        var flags: [String] = []
        switch direnvAllowed(directory) {
        case true?: flags.append(style.green("allowed"))
        case false?: flags.append(style.yellow("not allowed: run direnv allow"))
        case nil: flags.append(style.dim("direnv not installed"))
        }
        let loaded = ProcessInfo.processInfo.environment["DIRENV_DIR"] == "-" + directory.resolvingSymlinksInPath().path
        flags.append(loaded ? style.green("loaded") : style.dim("not loaded in this shell"))
        if let reason = skipReason(settings: settings) { flags.append(style.yellow("skipped: " + reason)) }
        print(style.bold(displayPath(file)) + "  " + flags.joined(separator: " · "))

        guard !envrc.environments.isEmpty else {
            print("  kcsecret loads nothing here.")
            return
        }
        let environment = try environmentArgument(parsed) ?? envrc.active
        let mappings = envrc.mappings(in: environment)
        if envrc.environments.count > 1 || !envrc.active.isEmpty || environment != envrc.active {
            let list = envrc.environments.map { env in
                let name = Envrc.displayName(env) + " (\(envrc.mappings(in: env).count))"
                return env == envrc.active ? style.bold(name + " ← direnv") : name
            }
            print("  environments: " + list.joined(separator: ", ") + style.dim("  · kcsecret use ENV to switch"))
            if environment != envrc.active { print("  checking \(style.bold(Envrc.displayName(environment))):") }
        }
        guard !mappings.isEmpty else {
            throw Failure("there is no environment \(Envrc.displayName(environment)) in \(displayPath(file))")
        }
        let store = try SecretStore.open(at: settings.keychainPath)
        let locked = store?.isLocked ?? false
        let width = mappings.map(\.variable.count).max() ?? 0
        var problems = 0
        for m in mappings {
            let label = "  " + m.variable.padding(toLength: width, withPad: " ", startingAt: 0) + "  ← " + m.secret
            let state: String
            if store == nil {
                state = style.red("✗ no keychain yet"); problems += 1
            } else if locked {
                state = style.dim("? keychain locked (it unlocks at the next read)")
            } else if !store!.contains(m.secret) {
                state = style.red("✗ not in the keychain"); problems += 1
            } else {
                switch store!.trust(of: m.secret) {
                case .thisBuild: state = style.green("✓")
                case .otherBuild:
                    state = style.yellow("! stored by another build: asks for the keychain password (see kcsecret doctor)")
                    problems += 1
                case .anyApplication: state = style.yellow("! readable by any app without a prompt"); problems += 1
                case .unknown: state = style.green("✓") + style.dim(" (access list not checked)")
                }
            }
            print(label + "  " + state)
        }
        if envrc.legacyLineCount > 0 {
            print(style.dim("  \(envrc.legacyLineCount) line(s) use the older format (one Touch ID prompt each); "
                + "any kcsecret link or unlink here converts them."))
        }
        if problems > 0 { throw Failure("", code: 1) }
    }

    // MARK: doctor

    /// Checks the installation end to end and says how to fix what is wrong. Reads only metadata:
    /// never a secret, so it asks for neither Touch ID nor a password.
    static func doctor(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [])
        guard parsed.positional.isEmpty else { throw Failure.usage("usage: kcsecret doctor") }
        let style = Style.stdout
        var problems = 0
        func ok(_ s: String) { print("\(style.green("✓")) \(s)") }
        func info(_ s: String) { print("\(style.dim("·")) \(s)") }
        func warn(_ s: String, fix: String) {
            problems += 1
            print("\(style.yellow("!")) \(s)\n    \(style.dim("→ " + fix))")
        }

        // The binary and its signature.
        let me = SecretStore.executablePath ?? executablePath()
        ok("kcsecret \(version) at \(displayPath(URL(fileURLWithPath: me)))")
        if let requirement = SecretStore.currentRequirement {
            if requirement.hasPrefix("cdhash") {
                warn("signed ad hoc: after every rebuild or update, macOS asks for the keychain password once per secret",
                     fix: "sign with a certificate: see README → Install → Signing, then ./install.sh")
            } else {
                let name = requirement.range(of: #"subject\.CN\] = "[^"]*""#, options: .regularExpression)
                    .map { String(requirement[$0].dropFirst(15).dropLast()) }
                ok("signed\(name.map { " by \($0)" } ?? ""): rebuilds keep the keychain's trust")
            }
        }
        if let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map({ "\($0)/kcsecret" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        {
            let resolved = URL(fileURLWithPath: onPath).resolvingSymlinksInPath().path
            if resolved != me {
                warn("`kcsecret` on your PATH is \(displayPath(URL(fileURLWithPath: onPath))), not this binary",
                     fix: "remove the other copy or put \(displayPath(URL(fileURLWithPath: me).deletingLastPathComponent())) first in PATH")
            }
        } else {
            warn("kcsecret is not on your PATH",
                 fix: "add to ~/.zshrc: export PATH=\"\(displayPath(URL(fileURLWithPath: me).deletingLastPathComponent())):$PATH\"")
        }

        // Config.
        if settings.configExists {
            ok("config \(displayPath(URL(fileURLWithPath: settings.configPath))) (name_template \"\(settings.config.nameTemplate)\")")
        } else {
            info("no config file: defaults in use (kcsecret config --init to customise)")
        }

        // direnv.
        if commandExists("direnv") {
            let hooked = ["~/.zshrc", "~/.bashrc", "~/.bash_profile", "~/.config/fish/config.fish"].contains { rc in
                ((try? String(contentsOfFile: expandTilde(rc), encoding: .utf8)) ?? "").contains("direnv hook")
            }
            let versionText = runProcess(["direnv", "version"])?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            if hooked {
                ok("direnv \(versionText), hooked into your shell")
            } else {
                warn("direnv \(versionText) is installed but not hooked into your shell, so .envrc files never load",
                     fix: "add to ~/.zshrc: eval \"$(direnv hook zsh)\"  (https://direnv.net/docs/hook.html)")
            }
        } else {
            warn("direnv is not installed, so .envrc files never load", fix: "brew install direnv, then hook it into your shell")
        }

        // Pauses and SSH.
        var pauses = loadPauses(settings)
        pauses.prune()
        for p in pauses.entries {
            let span = p.until.map { "until \(clock($0))" } ?? "until resumed"
            info(p.isGlobal ? "paused everywhere \(span): no .envrc loads secrets (kcsecret resume --global)"
                : "paused \(span): \(displayPath(URL(fileURLWithPath: p.scope)))")
        }
        if Session.isSSH(ProcessInfo.processInfo.environment) {
            info("SSH session: .envrc files " + (settings.config.skipOverSSH ? "skip their kcsecret section here" : "will ask for Touch ID on the Mac"))
        }

        // The keychain and its items.
        guard let store = try SecretStore.open(at: settings.keychainPath) else {
            info("no keychain yet at \(displayPath(URL(fileURLWithPath: settings.keychainPath)))-db: the first kcsecret set creates it")
            return finish(problems)
        }
        ok("keychain \(displayPath(URL(fileURLWithPath: store.path)))-db")
        if store.isLocked {
            info("the keychain is locked (as after a restart): the next read asks for its password once, then Touch ID only")
            info("items not checked while it is locked")
            return finish(problems)
        }
        let items = try store.items()
        var stale: [String] = []
        var open: [String] = []
        var unknown = 0
        for item in items {
            switch store.trust(of: item.name) {
            case .thisBuild: break
            case .otherBuild: stale.append(item.name)
            case .anyApplication: open.append(item.name)
            case .unknown: unknown += 1
            }
        }
        if stale.isEmpty, open.isEmpty {
            ok("\(items.count) secret(s)" + (unknown > 0 ? " (\(unknown) not checked)" : ", all readable with Touch ID only"))
        }
        if !stale.isEmpty {
            warn("stored by another kcsecret build, so reading asks for the keychain password: \(stale.joined(separator: ", "))",
                 fix: "at the next prompt enter the kcsecret keychain password and choose Always Allow (once per secret), "
                    + "or delete them in Keychain Access and store them again")
        }
        if !open.isEmpty {
            warn("readable by any app without a prompt: \(open.joined(separator: ", "))",
                 fix: "store them again with kcsecret set NAME, which restricts them to kcsecret")
        }
        finish(problems)
    }

    private static func finish(_ problems: Int) {
        print("")
        if problems == 0 {
            print(Style.stdout.green("Everything looks good."))
        } else {
            print(Style.stdout.yellow("\(problems) thing(s) to fix."))
            exit(1)
        }
    }

    // MARK: helpers

    /// The `.envrc` direnv would use here: in this folder or the nearest parent.
    static func nearestEnvrc(from directory: URL) -> URL? {
        var dir = directory.standardizedFileURL
        while true {
            let file = dir.appendingPathComponent(".envrc")
            if FileManager.default.fileExists(atPath: file.path) { return file }
            if dir.path == "/" { return nil }
            dir.deleteLastPathComponent()
        }
    }

    /// Whether direnv allows the `.envrc` in `directory`; nil if direnv is not installed.
    static func direnvAllowed(_ directory: URL) -> Bool? {
        guard commandExists("direnv"), let result = runProcess(["direnv", "status"], in: directory) else { return nil }
        // "Found RC allowed 0" (0 = allowed, 1 = not allowed, 2 = denied), or "true"/"false" before 2.33.
        guard let line = result.output.split(separator: "\n").first(where: { $0.hasPrefix("Found RC allowed ") }) else {
            return false
        }
        let value = line.dropFirst("Found RC allowed ".count)
        return value == "0" || value == "true"
    }
}
