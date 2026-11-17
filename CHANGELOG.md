# Changelog

All notable changes to kcsecret are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-11-14

First public release, under the MIT license.

### Added

- `install.sh` signs with your code-signing certificate when you have one, so rebuilds and updates
  no longer make macOS ask for the keychain password once per secret.
- `kcsecret import` moves variables from a `.env` file into the keychain and `.envrc`: an
  interactive checklist (likely credentials pre-ticked), `--all`, or the variables named on the
  command line. `--strip` removes them from the `.env` file afterwards; `--dry-run` shows the plan.
  Handles quotes, escapes, `export` prefixes, comments and multi-line values.
- `kcsecret env VAR=NAME...` loads several secrets after **one** Touch ID prompt. `.envrc` files
  now use it from a managed block, so a project with ten secrets asks once, not ten times.
- `kcsecret add`, `link` and `unlink` manage that block; `ksecret` is now a shortcut for `add`.
- Name templates: `{project}-{var_kebab}` by default, with `{var}`, `{var_lower}`, `{path}`
  (the project's folders under `projects_root`), `{folder}` and `{user}`, set in the config file or
  per run with `--template`. `{env}` tells several `.env` files apart (`prod` for `.env.prod`), and
  `kcsecret import .env.prod` reads another file. `kcsecret name` previews them without touching the keychain.
- `direnv allow` is no longer run for you unless `direnv_allow = true`: allowing approves the whole
  `.envrc`, which you should review first.
- A config file, `~/.config/kcsecret/config.toml` (`kcsecret config --init` writes a commented
  one): keychain path, name template, the command `.envrc` runs, clipboard clearing, `direnv allow`,
  git exclusion, the picker's default selection and stripping.
- `kcsecret run [VAR=NAME...] -- CMD` runs one command with the secrets in its environment only,
  after one Touch ID prompt, so they never reach your shell.
- `kcsecret status` shows what the nearest `.envrc` loads and whether each secret is ready;
  `kcsecret doctor` checks signature, `PATH`, config, direnv and each item's access list (finding
  items that would ask for the keychain password) and says how to fix problems. Neither reads a
  secret or prompts.
- Environments: one project can hold several sets of variables (default, `prod`, `staging`…).
  `import .env.prod` fills `prod`; the sets that direnv does not load are kept as comments in the
  `.envrc` block. `kcsecret use ENV` switches what direnv loads; `run`, `status`, `add`, `link`,
  `unlink` and `import` take `-E ENV`. The default name template is now `{project}-{env}-{var_kebab}`
  (same names as before for the default environment), and `import` refuses to overwrite a secret
  that another environment uses.
- `kcsecret export [-E ENV] [VAR...]` writes an environment's secrets and the plain variables of
  `.envrc` to a `.env` file (`.env.prod` for prod, mode 600, kept out of git) or stdout, for Docker
  and other tools that want a file. Asks which environment and variables when not given.
- `kcsecret pause [DURATION] [--global]` and `kcsecret resume` stop `.envrc` files from loading
  secrets (one project, or all), for example while the Mac is used remotely: entering the project
  says the kcsecret section was skipped, waits a second, and continues without prompting. `.envrc`
  is unchanged, so no `direnv allow` is needed. Over SSH this happens automatically
  (`skip_over_ssh`). Typed commands (`get`, `run`, `export`) are unaffected.
- `kcsecret list [--long]` lists stored names without Touch ID; `delete` takes several names.
- zsh completion for commands, secret names and `.env` variables.
- `--help`, `--version`, colored output (`NO_COLOR` respected), distinct exit codes (2 for usage
  errors, 130 for a cancelled picker).
- Universal (arm64 + x86_64) binaries on GitHub Releases, CI on macOS 14 and 15, unit tests.

### Changed

- The project is a Swift package (`swift build`); `install.sh` builds a release binary and accepts
  `--no-shell` and `--uninstall`.
- `.envrc` lines written by earlier versions (`export VAR="$(… kcsecret get NAME)"`) keep working,
  and move into the managed block the next time kcsecret edits that `.envrc`.

## [0.1.0] - 2026-11-13

Initial private version: `kcsecret set|get|delete` and the `ksecret` zsh function.

[Unreleased]: https://github.com/shatalov-alex/kcsecret/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/shatalov-alex/kcsecret/releases/tag/v1.0.0
[0.1.0]: https://github.com/shatalov-alex/kcsecret/commits/main
