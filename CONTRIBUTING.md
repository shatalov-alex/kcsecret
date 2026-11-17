# Contributing to kcsecret

Thanks for helping. Bug reports, documentation fixes and pull requests are all welcome.

## Ground rules

- **Never include a real secret** in an issue, a test, a fixture or a log. Use made-up values.
- Security problems go through [private vulnerability reporting](SECURITY.md), not public issues.
- Discuss larger changes in an issue first, so we agree on the approach before you write it.

## Development setup

Requirements: macOS 13 or later, Xcode 16 or the matching Command Line Tools (Swift 6), and
[direnv](https://direnv.net) to try `.envrc` changes end to end.

```zsh
git clone https://github.com/shatalov-alex/kcsecret.git
cd kcsecret
swift build          # or: make build
swift test           # or: make test
make lint            # zsh syntax check of install.sh and shell/ksecret.zsh
```

Run the debug build directly: `.build/debug/kcsecret help`.

### Trying changes without touching your real secrets

Point kcsecret at a throwaway keychain and config:

```zsh
security create-keychain -p test /tmp/kcsecret-dev.keychain
export KCSECRET_KEYCHAIN=/tmp/kcsecret-dev.keychain KCSECRET_CONFIG=/tmp/kcsecret-dev.toml
echo 'direnv_allow = false' > $KCSECRET_CONFIG
printf 'value' | .build/debug/kcsecret set demo
.build/debug/kcsecret list
# ...
security delete-keychain /tmp/kcsecret-dev.keychain
```

`get` and `env` always ask for Touch ID; there is deliberately no way to skip it.

Each new build has a new code signature, and an item's access list names the build that stored
it. Items stored by one build make macOS ask before another build can read them; that is
expected.

## Project layout

| Path | What it is |
| --- | --- |
| `Sources/KCSecretCore` | Pure logic, fully unit tested: `.env` parsing, the `.envrc` block, name templates, config |
| `Sources/KCSecretKeychain` | The keychain and Touch ID code (deprecated file-keychain APIs live here only) |
| `Sources/kcsecret` | The command line: argument parsing, commands, the interactive picker |
| `Tests/KCSecretCoreTests` | Swift Testing tests for `KCSecretCore` |
| `shell/ksecret.zsh` | The `ksecret` shortcut and zsh completion |
| `install.sh` | Builds and installs from a checkout |

Logic that can be tested without a keychain or a terminal belongs in `KCSecretCore`, with tests.

## Pull requests

1. Branch from `main`.
2. Keep the change focused; update `README.md`, `kcsecret help` and `shell/ksecret.zsh` when you
   add or change a command or option.
3. Add an entry under **Unreleased** in `CHANGELOG.md`.
4. Make sure `swift test` and `make lint` pass; CI runs both on macOS 15 and 26.

Code style: follow the surrounding code (4-space indentation in Swift, 2 in shell, lines up to
about 120 characters). Prefer clear names over comments; comment the *why*.

## Releasing (maintainers)

1. Move the **Unreleased** notes in `CHANGELOG.md` under a new version heading.
2. Update `version` in `Sources/kcsecret/Support.swift`.
3. Commit and push to `main`, then run `scripts/release.sh 1.2.3`.

The script runs on the maintainer's Mac, which holds the release certificate (made once with
`scripts/create_signing_certificate.sh`). It tests, builds a universal binary, signs it with that
certificate, and checks the version, the signature and that nothing personal (home folder, user
name, email address) ended up in the binary or the archive. Only then does it tag the version and
publish the archive, its SHA-256, the certificate and the changelog notes as a GitHub release.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By taking part you agree to
uphold it.
