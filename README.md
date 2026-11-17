<div align="center">

# kcsecret

**Project secrets in a macOS keychain of their own, unlocked with Touch ID, loaded by direnv.**

Stop keeping API tokens in plaintext `.env` files. Move them into the keychain in one command,
and get them back as environment variables when you `cd` into the project.

[![CI](https://github.com/shatalov-alex/kcsecret/actions/workflows/ci.yml/badge.svg)](https://github.com/shatalov-alex/kcsecret/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/shatalov-alex/kcsecret?sort=semver)](https://github.com/shatalov-alex/kcsecret/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)

</div>

```console
$ cd ~/code/shop
$ kcsecret import                       # pick what moves out of .env
Move which variables from .env into the keychain?
↑/↓ move · space toggle · a all · n none · enter confirm · q cancel
› ◉ OPENAI_API_KEY      → shop-openai-api-key  (51 chars, new)
  ◉ STRIPE_SECRET_KEY   → shop-stripe-secret-key  (107 chars, new)
  ○ PORT                → shop-port  (4 chars, new)
  ○ LOG_LEVEL           → shop-log-level  (5 chars, new)
2 of 4 selected

✓ OPENAI_API_KEY     → shop-openai-api-key
✓ STRIPE_SECRET_KEY  → shop-stripe-secret-key
created .envrc

$ cd .. && cd shop                      # one Touch ID prompt, and they are set
direnv: loading ~/code/shop/.envrc
direnv: export +OPENAI_API_KEY +STRIPE_SECRET_KEY
```

## Contents

- [Why](#why)
- [Install](#install)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Security model](#security-model)
- [FAQ](#faq)
- [Roadmap](#roadmap)
- [Contributing](#contributing) · [License](#license)

## Why

- **Not in the login keychain.** Secrets live in `~/Library/Keychains/kcsecret.keychain-db`,
  shown as **kcsecret** in Keychain Access, apart from **login**.
- **Readable by kcsecret only.** Each item's access list trusts only the `kcsecret` binary. Any
  other program gets the keychain's password dialog instead, including
  `security find-generic-password -w` and scripts, install hooks or AI agents running in your shell.
- **Touch ID on every read.** Day to day it is only your fingerprint (or your Mac password when
  no fingerprint is available, e.g. lid closed). The keychain password is needed once after a
  restart, and never after an update when kcsecret is [signed](#signing).
- **One prompt per project**, not one per variable: all of a project's secrets load together.
- **No secret on screen, in shell history or in a file.** `.envrc` holds only names.
- **No 128-character limit.** `security add-generic-password -w` cuts what you type at 128
  characters, and PyPI tokens are about 200. kcsecret reads the clipboard, stdin or `.env`.
- **Small and auditable.** One Swift binary, no dependencies, no network access, no daemon.

## Install

Requires macOS 13 or later and [direnv](https://direnv.net) hooked into your shell
(`brew install direnv`, then [hook it](https://direnv.net/docs/hook.html)).

### Homebrew (recommended)

```zsh
brew install shatalov-alex/tap/kcsecret
echo "source $(brew --prefix)/opt/kcsecret/share/kcsecret/ksecret.zsh" >> ~/.zshrc  # ksecret shortcut, tab completion
exec zsh
```

Update with `brew upgrade kcsecret`. Homebrew installs the signed release binary unchanged (see
[Prebuilt binary](#prebuilt-binary)), so the keychain keeps trusting kcsecret across upgrades.

### From source

Needs Xcode or the Command Line Tools (`xcode-select --install`).

```zsh
git clone https://github.com/shatalov-alex/kcsecret.git ~/.kcsecret
~/.kcsecret/install.sh        # builds ~/.local/bin/kcsecret and loads the zsh integration
exec zsh                      # or open a new terminal
```

`install.sh` options: `--no-shell` (leave `~/.zshrc` alone), `--uninstall`. Set `KCSECRET_BIN`
to install somewhere other than `~/.local/bin`. To update: `git -C ~/.kcsecret pull && ~/.kcsecret/install.sh`.

### Prebuilt binary

Each [release](https://github.com/shatalov-alex/kcsecret/releases) has a universal binary for
Apple silicon and Intel:

```zsh
v=v1.0.0  # the latest release
curl -fsSLO https://github.com/shatalov-alex/kcsecret/releases/download/$v/kcsecret-$v-macos-universal.tar.gz
curl -fsSLO https://github.com/shatalov-alex/kcsecret/releases/download/$v/kcsecret-$v-macos-universal.tar.gz.sha256
shasum -a 256 -c kcsecret-$v-macos-universal.tar.gz.sha256
tar -xzf kcsecret-$v-macos-universal.tar.gz
mkdir -p ~/.local/bin && mv kcsecret-$v-macos-universal/kcsecret ~/.local/bin/
```

Downloaded with a browser instead? The binary is not notarized, so macOS blocks it until you run
`xattr -d com.apple.quarantine ~/.local/bin/kcsecret`. For the `ksecret` shortcut and tab
completion, also source [`shell/ksecret.zsh`](shell/ksecret.zsh) from `~/.zshrc`.

Releases are signed with the project's self-signed certificate,
[`signing/release-certificate.pem`](signing/release-certificate.pem). Every release uses the same
one, so the keychain keeps trusting kcsecret when you update. To check that a binary comes from
this project:

```zsh
codesign -d -r- ~/.local/bin/kcsecret
```

The output must contain `8b9f34eab7b2214684acee8e01413860954e5f12`, the certificate's SHA-1 fingerprint.

### Signing

The keychain trusts kcsecret by its code signature. Sign it with a certificate, and every
rebuild or update keeps the same identity, so macOS never asks again.

`install.sh` signs with `$KCSECRET_SIGN_IDENTITY` if set, else the first valid code-signing
certificate in your keychain (Developer ID, then Apple Development, which Xcode creates for any
Apple ID). List yours with `security find-identity -v -p codesigning`.

No certificate? Make a self-signed one: **Keychain Access → Certificate Assistant → Create a
Certificate…**, name it e.g. `kcsecret`, type **Code Signing**, then run
`KCSECRET_SIGN_IDENTITY=kcsecret ./install.sh`. Without any certificate, kcsecret is signed ad hoc:
it still works, but after each rebuild macOS asks for the keychain password once per secret
(choose **Always Allow**).

> [!NOTE]
> When you switch an existing install to a signed build, macOS asks one last time per secret,
> because the items name the old build. Choose **Always Allow**; from then on it is Touch ID only.

## Quick start

**Move an existing `.env` into the keychain:**

```zsh
cd ~/code/shop
kcsecret import          # tick what to move (credentials are pre-ticked), press enter
```

**Add one secret** — copy it to the clipboard, then:

```zsh
ksecret shop-openai-key OPENAI_API_KEY   # store it, clear the clipboard, export it from .envrc
```

The first time, macOS asks you to choose a password for the new **kcsecret** keychain. Review
`.envrc` and run `direnv allow` once. From then on, entering the folder asks for Touch ID once and
sets the variables; leaving it unsets them.

## Usage

```text
kcsecret set NAME                   store the clipboard (or stdin, when piped) as NAME
kcsecret get NAME                   Touch ID, then print the secret
kcsecret delete NAME...             remove secrets
kcsecret list [--long]              list stored names (no Touch ID needed)

kcsecret add NAME [ENV_VAR]         set NAME, then export it as ENV_VAR from ./.envrc
kcsecret add [NAME] --env ENV_VAR   the same, naming the secret with your name template
kcsecret link NAME ENV_VAR          export an already stored secret from ./.envrc
kcsecret unlink ENV_VAR...          stop exporting (the secret stays in the keychain)
kcsecret import [ENV_VAR...]        move variables from .env into the keychain and ./.envrc

kcsecret run [VAR=NAME...] -- CMD   run CMD with the secrets in its environment only
kcsecret status                     what ./.envrc loads and whether each secret is ready
kcsecret doctor                     check the whole setup and say how to fix problems

kcsecret env ENV_VAR=NAME...        one Touch ID prompt, then `export` lines (what .envrc runs)
kcsecret config [--init|--path]     show settings, write a commented config file
```

`NAME` may contain letters, digits, `.`, `_` and `-`. Run `kcsecret help` for every option.
`ksecret …` is shorthand for `kcsecret add …`.

### Importing a `.env` file

```zsh
kcsecret import                          # interactive checklist for ./.env
kcsecret import OPENAI_API_KEY DB_URL    # just these, no questions
kcsecret import --all --strip            # everything, then delete them from .env
kcsecret import .env.prod -n             # dry run on another file (same as -f .env.prod)
kcsecret import -t '{var}' -p shop       # name items OPENAI_API_KEY…, {project} = shop
```

- The checklist pre-ticks names that look like credentials (`*_KEY`, `*TOKEN*`, `*SECRET*`,
  `*PASSWORD*`, `DATABASE_URL`, …) and leaves settings like `PORT` alone. Change that default
  with [`import_selection`](#configuration).
- The `.envrc` goes next to the `.env` file. Existing items with the same name are replaced.
- Each file fills its own [environment](#environments-and-env-files-for-docker): `.env` the
  default one, `.env.prod` the `prod` one (`-E NAME` picks another).
- The parser understands what dotenv and docker compose accept: `export` prefixes, comments,
  `'single'` (literal) and `"double"` (escapes) quotes, and multi-line values such as PEM keys.
  `${VAR}` references are stored as written, not expanded.
- `--strip` removes only the imported assignments and keeps every other line, comment and the
  file's permissions. Without it, kcsecret reminds you that the plaintext values are still there.
- Variables you leave in `.env` can still be loaded by direnv: add `dotenv_if_exists` to `.envrc`.

### What goes into `.envrc`

kcsecret owns one marked block and leaves the rest of the file alone:

```bash
layout python                      # your own lines stay as they are

# >>> kcsecret >>>
# Managed by kcsecret (kcsecret link / unlink / use). One Touch ID prompt loads them all.
eval "$("$HOME/.local/bin/kcsecret" env \
  OPENAI_API_KEY=shop-openai-api-key \
  STRIPE_SECRET_KEY=shop-stripe-secret-key)"
# <<< kcsecret <<<
```

After each change kcsecret keeps `.envrc` out of git (via `.git/info/exclude`, unless git already
ignores it). Review the file and run `direnv allow` to load it (or set `direnv_allow = true`). If you cancel Touch ID, the variables stay unset.

Lines written by kcsecret 0.x (`export VAR="$(… kcsecret get NAME)"`) still work, and move into
the block the next time kcsecret edits that file.

### Using secrets without exporting them: `kcsecret run`

An exported variable is readable by every program you start in that folder. For secrets you
use rarely, such as a publish token, load them for one command only:

```zsh
kcsecret run -- uv publish                                   # the nearest .envrc's secrets
kcsecret run UV_PUBLISH_TOKEN=personal-mylib-uv_publish_token -- uv publish   # or name them
```

One Touch ID prompt, then the command runs with the secrets in *its* environment; your shell
never sees them. Store such secrets with `--no-envrc` (import) or plain `kcsecret set`, so direnv
does not export them too.

### Environments, and `.env` files for Docker

A project can keep several sets of variables: the default one, and say `prod` and `staging`.
`kcsecret import .env.prod` stores the prod values (as `shop-prod-openai-api-key`, thanks to
`{env}` in the default [name template](#name-templates)) and keeps them in `.envrc` as comments
that only kcsecret reads:

```bash
# >>> kcsecret >>>
# Managed by kcsecret (kcsecret link / unlink / use). One Touch ID prompt loads them all.
eval "$("$HOME/.local/bin/kcsecret" env \
  OPENAI_API_KEY=shop-openai-api-key)"
# Other environments (kcsecret use ENV, export -E ENV, run -E ENV):
# kcsecret:prod OPENAI_API_KEY=shop-prod-openai-api-key
# <<< kcsecret <<<
```

```zsh
kcsecret use prod                  # direnv loads prod from now on (kcsecret use default to go back)
kcsecret use                       # pick from a list
kcsecret run -E prod -- ./deploy   # prod for one command, whatever direnv loads
kcsecret link -E prod shop-prod-db-url DATABASE_URL   # add, link and unlink take -E too
```

Some tools want a file. `kcsecret export` writes one environment as a `.env` file, after one
Touch ID prompt:

```zsh
kcsecret export                    # asks which environment (if several) and which variables
kcsecret export -E prod --all      # writes .env.prod next to .envrc, no questions
docker run --env-file <(kcsecret export -E prod -o -) my-image   # no file on disk
docker compose --env-file .env.prod up --build
```

- It writes the environment's secrets plus the plain `export FOO=bar` lines of `.envrc`
  (`--secrets-only` leaves those out). Lines whose value needs the shell, like `$(git rev-parse HEAD)`,
  are skipped with a warning. Name variables to export only those.
- The file is `.env` for the default environment and `.env.ENV` for the others, so it reads back
  with `kcsecret import`. `-o FILE` writes elsewhere; `-o -` prints to stdout.
- The file is created with mode `600` and kept out of git. kcsecret asks before overwriting it
  (`--force` skips that), and warns if git already tracks it. Nothing is written if a secret is
  missing.
- Values stay bare where possible, which `docker run --env-file` needs (it takes values
  literally); others are quoted the way docker compose and dotenv read them.
- **The file holds your secrets in plain text.** Delete it when the build is done, or better,
  avoid it: `-o -` with `<(…)` as above, or `kcsecret run -E prod -- docker compose up` when the
  compose file passes variables through (`environment: [API_KEY]` or `${API_KEY}`).

### Pausing: no Touch ID prompts while you are away

When the Mac is driven from somewhere else (a remote session, an agent working in your
terminal), nobody can answer a Touch ID prompt. Pause the loading:

```zsh
kcsecret pause              # the nearest .envrc skips its kcsecret section until you resume
kcsecret pause 2h           # ...or for two hours
kcsecret pause --global     # every project
kcsecret resume             # this project again (resume --global, or --all for every pause)
```

While paused, entering the project shows this, waits one second so you can read it, and carries on
without the secrets:

```text
kcsecret: skipped the kcsecret section of .envrc (4 secret(s) not loaded)
kcsecret: paused for this project until 18:30 · kcsecret resume to load secrets again
```

- The `.envrc` itself does not change, so `direnv allow` is not needed afterwards. kcsecret asks
  direnv to reload the project, so a pause also drops secrets already loaded in that shell.
- `kcsecret get`, `run` and `export` still work when you type them.
- Over SSH this happens on its own (`skip_over_ssh = true`), since nobody is at the sensor.
- `kcsecret status` and `doctor` show active pauses.

### Checking your setup: `kcsecret status` and `kcsecret doctor`

Neither reads a secret, so neither asks for Touch ID or a password.

```console
$ kcsecret status          # in a project
.envrc  allowed · loaded
  UV_PUBLISH_TOKEN  ← personal-mylib-uv_publish_token  ✓

$ kcsecret doctor          # anywhere
✓ kcsecret 1.0.0 at ~/.local/bin/kcsecret
✓ signed by Apple Development: …: rebuilds keep the keychain's trust
✓ config ~/.config/kcsecret/config.toml (name_template "{path}-{var_lower}")
✓ direnv 2.38.2, hooked into your shell
✓ keychain ~/Library/Keychains/kcsecret.keychain-db
! stored by another kcsecret build, so reading asks for the keychain password: old-token
    → at the next prompt enter the kcsecret keychain password and choose Always Allow …
```

`status` shows what the nearest `.envrc` loads (`-E ENV` checks another environment), whether each secret exists and can be read with
Touch ID alone, and whether direnv allows and has loaded the file. `doctor` checks the
signature, `PATH`, config, direnv and every item's access list, and says how to fix what is
wrong. Both exit with status 1 when something needs fixing, so they work in scripts.

## Configuration

Everything works without a config file. To customise, run `kcsecret config --init`, which writes
a commented `~/.config/kcsecret/config.toml` (respects `XDG_CONFIG_HOME`; `KCSECRET_CONFIG`
points elsewhere). `kcsecret config` shows the values in effect.

| Setting | Default | What it does |
| --- | --- | --- |
| `keychain` | `"~/Library/Keychains/kcsecret.keychain"` | The keychain file. `KCSECRET_KEYCHAIN` overrides it. |
| `name_template` | `"{project}-{env}-{var_kebab}"` | How `import` and `add --env` name items (below). |
| `projects_root` | `"~"` | The folder `{path}` is relative to. |
| `envrc_command` | `""` | How `.envrc` runs kcsecret. Empty: the binary's absolute path. `"kcsecret"` relies on `PATH`. |
| `clear_clipboard` | `true` | Clear the clipboard after storing from it. |
| `direnv_allow` | `false` | Run `direnv allow` after changing `.envrc`. Off for safety: allowing approves the whole file, so review it and allow it yourself. |
| `git_exclude` | `true` | Add `.envrc` to `.git/info/exclude` unless git ignores it already. |
| `import_selection` | `"secrets"` | What the import checklist pre-ticks: `"secrets"`, `"all"` or `"none"`. |
| `import_strip` | `false` | Remove imported variables from `.env` by default (`--keep` overrides). |
| `skip_over_ssh` | `true` | Over SSH, `.envrc` skips the kcsecret section (and says so) instead of waiting for Touch ID. |

### Name templates

| Placeholder | For `OPENAI_API_KEY` in `~/code/shop/api` (git root `shop`) |
| --- | --- |
| `{var}` | `OPENAI_API_KEY` |
| `{var_lower}` | `openai_api_key` |
| `{var_kebab}` | `openai-api-key` |
| `{project}` | `shop` — the git repository's folder, else the current folder; `--project` overrides |
| `{path}` | the project folder under `projects_root`, `/` → `-`: `work-acme-shop` for `~/Developer/work/acme/shop` with `projects_root = "~/Developer"` |
| `{env}` | the file's environment: `prod` for `.env.prod`, `staging` for `staging.env`, empty for `.env` |
| `{folder}` | `api` — the folder holding `.envrc` |
| `{user}` | your login name |

Some useful templates:

```toml
name_template = "{project}-{env}-{var_kebab}"  # shop-openai-api-key, shop-prod-openai-api-key (default)
name_template = "{var}"                        # OPENAI_API_KEY — share one secret across projects
name_template = "{project}.{folder}.{env}.{var_lower}"  # shop.api.openai_api_key — monorepos

# Names that say where a project lives: personal-mylib-uv_publish_token, work-acme-shop-prod-openai_api_key
projects_root = "~/Developer"
name_template = "{path}-{env}-{var_lower}"
```

Try a template before using it; `kcsecret name` only prints, it touches nothing:

```zsh
kcsecret name UV_PUBLISH_TOKEN -t '{path}-{var_lower}' -C ~/Developer/personal/mylib
```

`{env}` keeps environments apart: `DATABASE_URL` from `.env.prod` becomes
`work-acme-shop-prod-database_url` with `{path}-{env}-{var_lower}`, and plain `.env` gives
`work-acme-shop-database_url` (an empty placeholder takes one separator with it). Without `{env}`
every environment would get the same names, so `import` refuses when that would overwrite the
secret another environment uses. See [Environments](#environments-and-env-files-for-docker).

A template must contain a `{var…}` placeholder. Characters a name cannot hold become `-`.

## How it works

```text
           kcsecret import / add                       cd into the project
 .env ───────────────────────────► kcsecret keychain ◄──────────── .envrc (direnv)
 clipboard                         (Touch ID to read)   kcsecret env VAR=name …
                                         │
                                         └──► export VAR='…' into your shell
```

- Items are generic passwords (service = name, account = your login name) in a file-based
  keychain created on first use. It never locks on sleep or idle; after a restart the first read
  asks for its password once, then it is Touch ID only. Lock it by hand with
  `security lock-keychain ~/Library/Keychains/kcsecret.keychain-db`.
- Each item's access list names only the `kcsecret` build that stored it.
- `get` and `env` call LocalAuthentication (`deviceOwnerAuthentication`) before reading anything.
- The keychain is listed in Keychain Access but stays on this Mac; it is not synced via iCloud.
  To view a secret there, open **kcsecret**, double-click the item and tick **Show password**;
  macOS asks for the keychain's password, since Keychain Access is not on the access list.

## Security model

kcsecret protects secrets **at rest and from other programs**:

- Another program running as you cannot read an item without the kcsecret keychain's password,
  because the item's access list trusts only the kcsecret binary.
- kcsecret itself does not hand out a secret without Touch ID or your Mac password.
- Secrets never pass through your shell history, your screen or your project's files, unless
  you ask for a file with `kcsecret export` (mode 600, kept out of git, and yours to delete).

It does **not** protect a secret once it is in an environment variable: any program started in
that folder can read its environment, as with any variable. Load rarely used secrets for one
command with `kcsecret run` instead.

Other limits worth knowing:

- Access lists name kcsecret's code signature: with a certificate, any build you sign with it;
  ad hoc, the exact build. Any other binary cannot read secrets until you allow it in the dialog
  macOS shows. Only allow builds you made or downloaded yourself, and keep your signing
  certificate to yourself.
- kcsecret uses the file-based keychain APIs (`SecAccess`, `SecKeychainCreate`). Apple has
  deprecated them, but they remain the only way to give an item an access list without a signed
  app and entitlements, and they work on current macOS.

Found a problem? See [SECURITY.md](SECURITY.md).

## FAQ

<details>
<summary><b>Why not just use the login keychain or <code>security</code>?</b></summary>

Items you add with `security add-generic-password` are usually readable by `security` itself
without a prompt, so any script can read them. The login keychain is also unlocked whenever you
are logged in. kcsecret's items need both the kcsecret binary and your fingerprint.
</details>

<details>
<summary><b>How is this different from 1Password CLI, pass, sops or Doppler?</b></summary>

Those are excellent and do much more (sharing, syncing, teams). kcsecret is for one developer on
one Mac who wants project tokens out of plaintext files with no account, no subscription, no
GPG setup and no network. It is a single small binary built on what macOS already provides.
</details>

<details>
<summary><b>Does it work with bash or fish?</b></summary>

The `kcsecret` command and the `.envrc` it writes work with any shell direnv supports. Only the
`ksecret` shortcut and the tab completion are zsh-specific.
</details>

<details>
<summary><b>Can I sync secrets to another Mac?</b></summary>

No; the keychain stays on this Mac by design. On a new Mac, store the secrets again (or keep
the `.env` files somewhere safe and run `kcsecret import` there).
</details>

<details>
<summary><b>How do I remove everything?</b></summary>

`./install.sh --uninstall` removes the binary and the `~/.zshrc` line. Then delete the
**kcsecret** keychain in Keychain Access (or `security delete-keychain ~/Library/Keychains/kcsecret.keychain-db`),
and the kcsecret blocks from your `.envrc` files.
</details>

## Roadmap

Ideas under consideration, roughly in order. Comments and pull requests welcome.

- **`kcsecret rename OLD NEW`**: rename a secret and update every `.envrc` that uses it, e.g. to
  move to a new name template (one Touch ID prompt).
- **`kcsecret scan [DIR]`**: find plaintext `.env` files under a folder, flag the ones git tracks,
  and offer to import them.
- **`kcsecret get --copy`**: copy a secret to the clipboard and clear it after 30 seconds, for
  pasting into web forms.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
development setup (including how to test against a throwaway keychain) and
[CHANGELOG.md](CHANGELOG.md) for what changed.

## License

[MIT](LICENSE) © 2026 Alex Shatalov
