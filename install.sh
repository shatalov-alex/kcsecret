#!/bin/zsh
# Build kcsecret from this checkout, install it, and load the zsh integration from ~/.zshrc.
#
#   ./install.sh                 build and install into ~/.local/bin (or $KCSECRET_BIN)
#   ./install.sh --no-shell      ...without touching ~/.zshrc
#   ./install.sh --uninstall     remove the binary and the ~/.zshrc line (secrets stay in the keychain)
#
# Signing: the keychain trusts kcsecret by its code signature. With a code-signing certificate
# (Apple Development, Developer ID, or a self-signed one), every rebuild keeps the same identity
# and macOS never asks again. install.sh uses $KCSECRET_SIGN_IDENTITY, else the first valid
# certificate it finds. Without one it signs ad hoc, and macOS asks for the keychain password
# once per secret after each rebuild.
set -euo pipefail

here=${0:A:h}
bin=${KCSECRET_BIN:-$HOME/.local/bin}
zshrc=${ZDOTDIR:-$HOME}/.zshrc
shell_line="source ${here/#$HOME/~}/shell/ksecret.zsh"
mode=install
touch_shell=1

for arg in "$@"; do
  case $arg in
    --uninstall) mode=uninstall ;;
    --no-shell) touch_shell=0 ;;
    -h|--help) sed -n '2,8s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) print -u2 "install.sh: unknown option $arg"; exit 2 ;;
  esac
done

say() { print -P "%F{cyan}==>%f $*"; }

remove_shell_line() {
  [[ -f $zshrc ]] || return 0
  if grep -q 'ksecret\.zsh' "$zshrc"; then
    sed -i '' '/ksecret\.zsh/d' "$zshrc"
    say "removed the ksecret line from $zshrc"
  fi
}

if [[ $mode == uninstall ]]; then
  rm -f "$bin/kcsecret" && say "removed $bin/kcsecret"
  (( touch_shell )) && remove_shell_line
  say "your secrets are still in the kcsecret keychain; delete it in Keychain Access if you no longer need them"
  exit 0
fi

[[ $(uname -s) == Darwin ]] || { print -u2 "kcsecret runs on macOS only"; exit 1; }
command -v swift >/dev/null || { print -u2 "swift not found: install Xcode or run xcode-select --install"; exit 1; }

say "building kcsecret (release)"
swift build --package-path "$here" -c release --product kcsecret
built=$(swift build --package-path "$here" -c release --product kcsecret --show-bin-path)/kcsecret

mkdir -p "$bin"
rm -f "$bin/kcsecret"  # replace, never overwrite in place: macOS caches the old signature per file
cp "$built" "$bin/kcsecret"
identity=${KCSECRET_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  for kind in "Developer ID Application" "Apple Development" ""; do
    identity=$(print -r -- "$identities" | grep -F "\"$kind" | head -1 | awk '{print $2}' || true)
    [[ -n $identity ]] && break
  done
fi
if [[ -n $identity ]] && codesign --force --sign "$identity" --identifier kcsecret --timestamp=none "$bin/kcsecret" 2>/dev/null; then
  name=$(security find-identity -v -p codesigning | grep -F "$identity" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
  say "signed with ${name:-$identity}: rebuilds keep the same identity, so the keychain keeps trusting kcsecret"
else
  codesign --force --sign - --identifier kcsecret "$bin/kcsecret"
  print -P "%F{yellow}note:%f signed ad hoc (no code-signing certificate found). After each rebuild macOS asks for the"
  print -P "      keychain password once per secret. To avoid that, see README → Install → Signing."
fi
say "installed $bin/kcsecret ($("$bin/kcsecret" --version))"

if (( touch_shell )); then
  if grep -qxF "$shell_line" "$zshrc" 2>/dev/null; then
    say "$zshrc already loads ksecret"
  else
    remove_shell_line  # an older location
    print -r -- "$shell_line" >> "$zshrc"
    say "added to $zshrc: $shell_line"
    say "open a new terminal, or run: source $zshrc"
  fi
fi

if [[ :$PATH: != *:$bin:* ]]; then
  print -P "%F{yellow}note:%f $bin is not on your PATH; add it in $zshrc:  export PATH=\"${bin/#$HOME/\$HOME}:\$PATH\""
fi
command -v direnv >/dev/null || print -P "%F{yellow}note:%f direnv is not installed: brew install direnv  (https://direnv.net)"
