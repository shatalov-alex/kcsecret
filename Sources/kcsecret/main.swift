// kcsecret: secrets in a macOS keychain of their own, read back with Touch ID and exported per
// project through direnv. See README.md, or `kcsecret help`.
import Foundation

let help = """
    kcsecret \(version): secrets in a keychain of their own, read with Touch ID, exported by direnv

    USAGE
      kcsecret <command> [options]

    STORE AND READ
      set NAME                    store the clipboard (or stdin, when piped) as NAME
      get NAME                    Touch ID, then print the secret
      delete NAME...              remove secrets
      list [-l|--long]            list the stored names (no Touch ID; -l adds dates)

    PER-PROJECT VARIABLES (./.envrc, loaded by direnv)
      add NAME [ENV_VAR]          set NAME, then export it as ENV_VAR from ./.envrc
      add [NAME] --env ENV_VAR    the same; without NAME, the name comes from the name template
      link NAME ENV_VAR           export an already stored secret as ENV_VAR from ./.envrc
      unlink ENV_VAR...           stop exporting variables (the secrets stay in the keychain)
          add, link and unlink take -E ENVIRONMENT (default: the one direnv loads)
      import [FILE] [ENV_VAR...]  move variables from a .env file into the keychain and its .envrc
          FILE, -f, --file PATH   the file to read (default: .env), e.g. .env.prod; its folder
                                  gets the .envrc, and the variables go to environment "prod"
                                  ({env} in the name template becomes "prod" too)
          -E, --environment ENV   another environment than the file name gives
          -a, --all               every variable, without asking
          -t, --template T        name template, e.g. "{project}-{env}-{var_kebab}" (see config)
          -p, --project NAME      the value of {project} (default: the git repository's folder)
              --strip             remove the imported variables from the .env file afterwards
              --keep              keep them, even if the config says import_strip = true
              --no-envrc          only store the secrets; leave .envrc alone
          -n, --dry-run           show what would happen
        Without ENV_VAR or --all, a checklist opens with likely credentials ticked.

    ENVIRONMENTS (default, prod, staging…: one set of variables each in .envrc)
      use [ENVIRONMENT]           switch the environment direnv loads (no argument: pick or list)
      export [ENV_VAR...]         one Touch ID prompt, then write a .env file (e.g. for Docker):
                                  the secrets and the plain `export FOO=bar` lines of .envrc
          -E, --environment ENV   which environment (asked when there are several), e.g. prod
          -o, --output FILE       where (default: .env, or .env.ENV next to .envrc; - for stdout)
          -a, --all               every variable, without the checklist
              --secrets-only      leave out the plain variables
              --force             overwrite the file without asking

    PAUSE (nothing asks for Touch ID, e.g. while the Mac is used remotely)
      pause [DURATION]            the nearest .envrc skips its kcsecret section, and says so,
                                  until kcsecret resume or for DURATION (30m, 2h, 1d, 1h30m)
          -g, --global            every project
      resume [--global|--all]     load secrets again (--all: end every pause)
        Over SSH the kcsecret section is skipped too (skip_over_ssh in the config).
        get, run and export still work while paused.

    USE AND CHECK
      run [-E ENV] [ENV_VAR=NAME...] -- CMD   run CMD with the secrets in its environment only
                                  (one Touch ID prompt); by default those of the nearest .envrc
      status [-E ENV]             what ./.envrc loads, and whether each secret is ready (no prompts)
      doctor                      check the setup: signature, PATH, direnv, keychain (no prompts)

    OTHER
      name ENV_VAR... [-t T] [-C DIR] [-f FILE]   preview names a template gives (touches nothing)
      env ENV_VAR=NAME...         one Touch ID prompt, then `export ENV_VAR='…'` lines (.envrc runs this)
      config [--init|--path]      show the settings, write a commented config file, or print its path
      help, version

    ENVIRONMENT
      KCSECRET_KEYCHAIN           the keychain file (default: ~/Library/Keychains/kcsecret.keychain)
      KCSECRET_CONFIG             the config file (default: ~/.config/kcsecret/config.toml)
      KCSECRET_PAUSES             the pause state (default: ~/.local/state/kcsecret/paused)
      NO_COLOR                    turn colors off

    EXAMPLES
      pbcopy < token.txt; kcsecret add shop-openai-key OPENAI_API_KEY
      kcsecret import                       # pick from ./.env
      kcsecret import --all --strip         # move everything, then delete it from .env
      kcsecret import .env.prod STRIPE_SECRET_KEY
      kcsecret run -- uv publish            # the token exists only for this one command
      kcsecret export -E prod && docker compose --env-file .env.prod up --build
      kcsecret use prod                     # direnv loads the prod secrets from now on

    Docs: https://github.com/shatalov-alex/kcsecret
    """

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? "help"
let rest = arguments.dropFirst()

do {
    let ownArguments = rest.prefix { $0 != "--" }  // after `--`, arguments belong to `run`'s command
    if ["help", "-h", "--help"].contains(command) || ownArguments.contains("--help") || ownArguments.contains("-h") {
        print(help)
        exit(0)
    }
    if ["version", "-v", "--version"].contains(command) {
        print("kcsecret \(version)")
        exit(0)
    }
    let settings = try Settings.load()
    switch command {
    case "set": try Commands.set(rest, settings: settings)
    case "get": try Commands.get(rest, settings: settings)
    case "delete", "rm": try Commands.delete(rest, settings: settings)
    case "list", "ls": try Commands.list(rest, settings: settings)
    case "add": try Commands.add(rest, settings: settings)
    case "link": try Commands.link(rest, settings: settings)
    case "unlink": try Commands.unlink(rest, settings: settings)
    case "import": try Commands.importDotEnv(rest, settings: settings)
    case "run": try Commands.run(rest, settings: settings)
    case "use": try Commands.use(rest, settings: settings)
    case "pause": try Commands.pause(rest, settings: settings)
    case "resume": try Commands.resume(rest, settings: settings)
    case "export": try Commands.export(rest, settings: settings)
    case "status": try Commands.status(rest, settings: settings)
    case "doctor": try Commands.doctor(rest, settings: settings)
    case "name": try Commands.name(rest, settings: settings)
    case "env": try Commands.env(rest, settings: settings)
    case "config": try Commands.config(rest, settings: settings)
    default: throw Failure.usage("unknown command '\(command)' (see kcsecret help)")
    }
} catch let failure as Failure {
    if !failure.message.isEmpty { Log.error(failure.message) }
    exit(failure.code)
} catch {
    Log.error("\(error)")
    exit(1)
}
