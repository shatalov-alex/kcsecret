import Foundation
import KCSecretCore

/// `pause` and `resume`: stop `.envrc` files from loading secrets for a while (for one project, or
/// with --global for all), so nothing asks for Touch ID when nobody can answer, e.g. while the Mac
/// is driven remotely. Commands typed by hand keep working.
extension Commands {
    // MARK: pause

    /// `kcsecret pause [DURATION] [--global]`
    static func pause(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [.flag("--global", "-g")])
        guard parsed.positional.count <= 1 else { throw Failure.usage("usage: kcsecret pause [DURATION] [--global]") }
        var until: Date?
        if let text = parsed.positional.first {
            guard let seconds = Pauses.duration(text) else {
                throw Failure.usage("'\(text)' is not a duration: use e.g. 30m, 2h, 1d or 1h30m")
            }
            until = Date().addingTimeInterval(seconds)
        }
        let global = parsed.has("--global")
        let project = global ? nil : try pauseScope()
        var pauses = loadPauses(settings)
        pauses.pause(project?.path ?? Pauses.everywhere, until: until)
        try savePauses(pauses, settings)

        let what = project.map { "kcsecret section of \(displayPath($0.appendingPathComponent(".envrc")))" }
            ?? "kcsecret section of every .envrc"
        print("paused: the \(what) loads no secrets " + (until.map { "until \(clock($0))" } ?? "until kcsecret resume"
            + (global ? " --global" : "")))
        Log.note(Style.stderr.dim("kcsecret get / run / export still work when you type them."))
        reloadDirenv(project)
    }

    // MARK: resume

    /// `kcsecret resume [--global] [--all]`
    static func resume(_ args: ArraySlice<String>, settings: Settings) throws {
        let parsed = try Arguments(args, options: [.flag("--global", "-g"), .flag("--all")])
        guard parsed.positional.isEmpty else { throw Failure.usage("usage: kcsecret resume [--global] [--all]") }
        var pauses = loadPauses(settings)
        pauses.prune()
        if parsed.has("--all") {
            let count = pauses.entries.count
            for e in pauses.entries { pauses.resume(e.scope) }
            try savePauses(pauses, settings)
            print(count == 0 ? "nothing was paused" : "resumed \(count) pause(s)")
            reloadDirenv(nil)
            return
        }
        let project = parsed.has("--global") ? nil : try pauseScope()
        let scope = project?.path ?? Pauses.everywhere
        let resumed = pauses.resume(scope)
        if resumed {
            try savePauses(pauses, settings)
            print("resumed: " + (project.map { "\(displayPath($0.appendingPathComponent(".envrc"))) loads its secrets again" }
                ?? "every .envrc loads its secrets again"))
        } else {
            print(project == nil ? "there was no global pause" : "this project was not paused")
        }
        if project != nil, let global = pauses.entry(for: Pauses.everywhere) {
            Log.warn("every project is still paused" + (global.until.map { " until \(clock($0))" } ?? "")
                + ": kcsecret resume --global")
        }
        if resumed { reloadDirenv(project) }
    }

    // MARK: used by env, status and doctor

    /// Why `.envrc` should load nothing right now, or nil.
    static func skipReason(settings: Settings) -> String? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = (nearestEnvrc(from: cwd)?.deletingLastPathComponent() ?? cwd).resolvingSymlinksInPath().path
        if let pause = loadPauses(settings).covering(folder) {
            let span = pause.until.map { "until \(clock($0))" } ?? "until you resume"
            return pause.isGlobal
                ? "paused for every project \(span) · kcsecret resume --global to load secrets again"
                : "paused for this project \(span) · kcsecret resume to load secrets again"
        }
        if settings.config.skipOverSSH, Session.isSSH(ProcessInfo.processInfo.environment) {
            return "SSH session, where nobody can touch the Mac's sensor · kcsecret run -- CMD still works; "
                + "skip_over_ssh = false in the config turns this off"
        }
        return nil
    }

    /// Says loudly that the secrets were not loaded, then waits a second so it is read.
    static func announceSkip(_ reason: String, count: Int) {
        let style = Style.stderr
        FileHandle.standardError.write(Data((
            style.yellow(style.bold("kcsecret: skipped the kcsecret section of .envrc")) + style.yellow(" (\(count) secret(s) not loaded)\n")
                + style.yellow("kcsecret: ") + reason + "\n").utf8))
        Thread.sleep(forTimeInterval: 1)
    }

    static func loadPauses(_ settings: Settings) -> Pauses {
        Pauses(text: (try? String(contentsOfFile: settings.pausesPath, encoding: .utf8)) ?? "")
    }

    // MARK: helpers

    /// The folder of the nearest `.envrc`, symlinks resolved: what a project pause covers.
    private static func pauseScope() throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let file = nearestEnvrc(from: cwd) else {
            throw Failure("no .envrc here or in a parent folder: pause a project from inside it, or use --global")
        }
        return file.deletingLastPathComponent().resolvingSymlinksInPath()
    }

    private static func savePauses(_ pauses: Pauses, _ settings: Settings) throws {
        var pauses = pauses
        pauses.prune()
        let url = URL(fileURLWithPath: settings.pausesPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pauses.render().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Failure("cannot write \(settings.pausesPath): \(error.localizedDescription)")
        }
    }

    /// Makes direnv re-read the project's `.envrc` at the next prompt (or the one this shell has
    /// loaded, for a global change), so the change applies now rather than at the next cd.
    private static func reloadDirenv(_ project: URL?) {
        guard commandExists("direnv") else { return }
        var folder = project
        if folder == nil, let loaded = ProcessInfo.processInfo.environment["DIRENV_DIR"], loaded.hasPrefix("-") {
            folder = URL(fileURLWithPath: String(loaded.dropFirst()))
        }
        guard let folder else {
            Log.note(Style.stderr.dim("Applies the next time direnv loads an .envrc (cd into a project, or direnv reload)."))
            return
        }
        if runProcess(["direnv", "reload"], in: folder)?.status == 0 {
            Log.note(Style.stderr.dim("direnv reloads \(displayPath(folder.appendingPathComponent(".envrc"))) at your next prompt."))
        }
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d HH:mm"
        return f.string(from: date)
    }
}
