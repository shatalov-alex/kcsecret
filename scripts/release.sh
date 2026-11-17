#!/bin/bash

# Publishes kcsecret X.Y.Z: tests, builds a universal binary signed with the release certificate
# (see create_signing_certificate.sh), checks it, tags vX.Y.Z and creates the GitHub release.
#
# Usage: scripts/release.sh X.Y.Z
#
# Then it points the Homebrew formula in the tap (a clone of shatalov-alex/homebrew-tap, by default
# ../homebrew-tap next to this repository; KCSECRET_TAP sets another folder) at the new release.
#
# Before running: notes under "## [X.Y.Z] - date" in CHANGELOG.md, `version` set in
# Sources/kcsecret/Support.swift, all committed and pushed to main.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
TAG="v$VERSION"
REPO="shatalov-alex/kcsecret"
CERT="signing/release-certificate.pem"
NAME="kcsecret-$TAG-macos-universal"
DIST="dist"
SCRATCH=".build/release-universal"
TAP="${KCSECRET_TAP:-../homebrew-tap}"
FORMULA="$TAP/Formula/kcsecret.rb"

fail() { echo "error: $1" >&2; exit 1; }
step() { echo "==> $1"; }

# MARK: - Checks
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: $0 X.Y.Z"
command -v gh >/dev/null || fail "the GitHub CLI (gh) is required"
[ -f "$CERT" ] || fail "$CERT is missing: run scripts/create_signing_certificate.sh once"
CERT_SHA1="$(/usr/bin/openssl x509 -in "$CERT" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
security find-identity -p codesigning | grep -q "$CERT_SHA1" || fail "the release certificate $CERT_SHA1 is not in the keychain"
[ "$(git branch --show-current)" = main ] || fail "releases are made from main"
[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not in sync with origin/main"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG already exists"
grep -qx "let version = \"$VERSION\"" Sources/kcsecret/Support.swift || fail "Sources/kcsecret/Support.swift is not at $VERSION"
[ -f "$FORMULA" ] || fail "no Homebrew formula at $FORMULA: clone shatalov-alex/homebrew-tap there, or set KCSECRET_TAP"
[ -z "$(git -C "$TAP" status --porcelain)" ] || fail "the tap ($TAP) has uncommitted changes"
git -C "$TAP" pull -q --ff-only || fail "cannot update the tap ($TAP)"
CHANGES="$(awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {on=1; next} /^## \[/ {on=0} on' CHANGELOG.md | grep -v '^\[.*\]: ')"
[ -n "$(tr -d '[:space:]' <<<"$CHANGES")" ] || fail "CHANGELOG.md has no notes under ## [$VERSION]"

# MARK: - Build
step "testing"
swift test 2>&1 | tail -1
step "building (arm64 + x86_64)"
rm -rf "$SCRATCH" "$DIST"
# The prefix map keeps this folder's path out of the binary
swift build -c release --arch arm64 --arch x86_64 --product kcsecret --scratch-path "$SCRATCH" \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD/=" >/dev/null
BIN="$DIST/$NAME/kcsecret"
mkdir -p "$DIST/$NAME"
cp "$(swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" --show-bin-path)/kcsecret" "$BIN"
strip -S -x "$BIN"  # debug symbols name the object files' paths
codesign --force --sign "$CERT_SHA1" --identifier kcsecret --options runtime --timestamp=none "$BIN"
cp LICENSE README.md "$DIST/$NAME/"
# No owner names and no extended attributes in the archive
(cd "$DIST" && COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname root --gname wheel \
    -czf "$NAME.tar.gz" "$NAME" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")

# MARK: - Self-check
step "checking"
[ "$("$BIN" --version)" = "kcsecret $VERSION" ] || fail "the binary says $("$BIN" --version), not kcsecret $VERSION"
lipo "$BIN" -verify_arch arm64 x86_64 || fail "the binary is not universal"
codesign --verify --strict "$BIN" || fail "the signature does not verify"
codesign -d -r- "$BIN" 2>&1 | grep -qi "$CERT_SHA1" || fail "the binary is not signed with the release certificate"
[ "$(codesign -dvv "$BIN" 2>&1 | grep '^Authority=')" = "Authority=kcsecret Self-Signed" ] \
    || fail "the signature names another certificate"
# Nothing personal anywhere in what gets published: no home folder, user name or email address
leaks="$( { strings -a "$BIN"; codesign -dvvv "$BIN" 2>&1 | grep -v "^Executable="; /usr/bin/openssl x509 -in "$CERT" -noout -text;
           tar -tvzf "$DIST/$NAME.tar.gz"; } \
         | grep -E -i -e "$HOME" -e "$USER" -e "$(id -un)" -e '[a-z0-9._%+-]+@[a-z0-9-]+\.[a-z]{2,}' | sort -u || true)"
[ -z "$leaks" ] || fail "personal details in the release, nothing was published:"$'\n'"$leaks"
echo "    signed by kcsecret Self-Signed ($CERT_SHA1), no personal details"

# MARK: - Publish
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
SHA1_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"$CERT_SHA1")"
cat > "$NOTES" <<NOTES
$CHANGES

## Install

\`\`\`zsh
curl -fsSLO https://github.com/$REPO/releases/download/$TAG/$NAME.tar.gz
curl -fsSLO https://github.com/$REPO/releases/download/$TAG/$NAME.tar.gz.sha256
shasum -a 256 -c $NAME.tar.gz.sha256
tar -xzf $NAME.tar.gz
mkdir -p ~/.local/bin && mv $NAME/kcsecret ~/.local/bin/
\`\`\`

Downloaded with a browser instead? macOS then blocks the binary, as it is not notarized; allow it with
\`xattr -d com.apple.quarantine ~/.local/bin/kcsecret\`. For the \`ksecret\` shortcut and tab completion,
source [\`shell/ksecret.zsh\`](https://github.com/$REPO/blob/$TAG/shell/ksecret.zsh) from \`~/.zshrc\`.
Requires macOS 13 or later, Apple silicon or Intel.

## Signature

Releases are signed with the project's self-signed certificate,
[\`signing/release-certificate.pem\`](https://github.com/$REPO/blob/$TAG/$CERT). Every release uses the same one,
so the keychain keeps trusting kcsecret across updates. To check a binary comes from this project:

\`\`\`zsh
codesign -d -r- ~/.local/bin/kcsecret   # must show $SHA1_LOWER
\`\`\`
NOTES

step "tagging $TAG"
git tag -a "$TAG" -m "kcsecret $VERSION"
git push -q origin "$TAG"
step "creating the GitHub release"
gh release create "$TAG" -R "$REPO" --verify-tag --latest --title "kcsecret $VERSION" --notes-file "$NOTES" \
    "$DIST/$NAME.tar.gz" "$DIST/$NAME.tar.gz.sha256" "$CERT"
echo "released: https://github.com/$REPO/releases/tag/$TAG"

# MARK: - Homebrew
step "updating the Homebrew formula"
TAR_SHA="$(cut -d' ' -f1 < "$DIST/$NAME.tar.gz.sha256")"
ZSH_SHA="$(shasum -a 256 shell/ksecret.zsh | cut -d' ' -f1)"
# The formula's first url/sha256 pair is the release archive, the second the zsh integration
sed -i '' -E \
    -e "s#/releases/download/v[0-9.]+/kcsecret-v[0-9.]+-macos-universal.tar.gz#/releases/download/$TAG/$NAME.tar.gz#" \
    -e "s#/kcsecret/v[0-9.]+/shell/ksecret.zsh#/kcsecret/$TAG/shell/ksecret.zsh#" \
    -e "1,/sha256 \"/ s/sha256 \"[0-9a-f]+\"/sha256 \"$TAR_SHA\"/" \
    "$FORMULA"
awk -v s="$ZSH_SHA" '/resource "ksecret.zsh"/ {r=1} r && /sha256 "/ {sub(/"[0-9a-f]+"/, "\"" s "\""); r=0} {print}' \
    "$FORMULA" > "$FORMULA.new" && mv "$FORMULA.new" "$FORMULA"
grep -q "$TAR_SHA" "$FORMULA" && grep -q "$ZSH_SHA" "$FORMULA" || fail "could not update $FORMULA; edit it by hand"
git -C "$TAP" commit -q -am "kcsecret $VERSION"
git -C "$TAP" push -q
echo "brew upgrade kcsecret now installs $VERSION"
