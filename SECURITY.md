# Security policy

kcsecret guards credentials, so security reports get priority.

## Supported versions

Fixes go into the latest release. Please upgrade before reporting.

| Version | Supported |
| --- | --- |
| 1.x | ✅ |
| < 1.0 | ❌ |

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/shatalov-alex/kcsecret/security/advisories/new).

Include what you found, how to reproduce it, and the impact you see. You can expect an
acknowledgement within a few days and a fix or a plan within two weeks for confirmed issues. You
will be credited in the release notes unless you prefer otherwise.

## Threat model

What kcsecret is designed to protect against, and what it is not, is described in
[the README's security section](README.md#security-model). In short:

**In scope**: other programs (scripts, package install hooks, AI agents, `security
find-generic-password`) reading a secret from the keychain without your Touch ID or password;
secrets landing in shell history, on screen, in files in your project, or in git.

**Out of scope**: anything that runs as you *after* a secret is exported into a shell's
environment (it can read the environment, like any variable); an attacker with root or with your
login and keychain passwords; a modified kcsecret binary that you then allow in the keychain
dialog.
