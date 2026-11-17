# kcsecret zsh integration: the `ksecret` shortcut and tab completion.
# Loaded from ~/.zshrc by install.sh:  source /path/to/kcsecret/shell/ksecret.zsh
#
#   ksecret NAME              store the clipboard (or stdin) as NAME
#   ksecret NAME ENV_VAR      ...and export it as ENV_VAR from ./.envrc
#   ksecret --env ENV_VAR     ...naming the secret with your name template
#
# `ksecret` is `kcsecret add`; see `kcsecret help` for everything else.

ksecret() {
  if (( $# == 0 )) || [[ $1 == -h || $1 == --help ]]; then
    print -u2 "usage: ksecret NAME [ENV_VAR]  |  ksecret --env ENV_VAR   (copy the secret first, or pipe it in)"
    return 2
  fi
  local bin=${commands[kcsecret]:-$HOME/.local/bin/kcsecret}
  "$bin" add "$@"
}

_kcsecret_names() {
  local -a names
  names=(${(f)"$(command kcsecret list 2>/dev/null)"})
  _describe -t secrets 'secret' names
}

_kcsecret_dotenv_vars() {
  local file=${opt_args[-f]:-${opt_args[--file]:-.env}}
  [[ -r $file ]] || return 1
  local -a vars
  vars=(${(f)"$(command sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' -- $file)"})
  _describe -t variables 'variable' vars
}

_kcsecret_envrc_vars() {
  [[ -r .envrc ]] || return 1
  local -a vars
  vars=(${(f)"$(command sed -nE '/^# >>> kcsecret >>>/,/^# <<< kcsecret <<</s/^[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' .envrc)"})
  _describe -t variables 'variable' vars
}

_kcsecret_environments() {
  local dir=$PWD
  while [[ ! -r $dir/.envrc && $dir != / ]]; do dir=${dir:h}; done
  [[ -r $dir/.envrc ]] || return 1
  local -a envs
  envs=(${(u)${(f)"$(command sed -nE '/^# >>> kcsecret >>>/,/^# <<< kcsecret <<</{s/^# kcsecret:([A-Za-z0-9._-]+) .*/\1/p;s/^# kcsecret-use ([A-Za-z0-9._-]+)$/\1/p;}' $dir/.envrc)"}} default)
  _describe -t environments 'environment' envs
}

_kcsecret() {
  local -a commands
  commands=(
    'set:store the clipboard (or stdin) as NAME'
    'get:Touch ID, then print a secret'
    'delete:remove secrets'
    'list:list the stored names'
    'add:store a secret and export it from ./.envrc'
    'link:export a stored secret from ./.envrc'
    'unlink:stop exporting variables from ./.envrc'
    'import:move variables from a .env file into the keychain'
    'name:preview the names a template gives'
    'run:run a command with the secrets in its environment only'
    'use:switch the environment direnv loads'
    'pause:stop .envrc loading secrets (this project, or --global)'
    'resume:load secrets again after a pause'
    'export:write an environment to a .env file (e.g. for Docker)'
    'status:what ./.envrc loads and whether each secret is ready'
    'doctor:check the setup'
    'env:print export lines for ENV_VAR=NAME pairs'
    'config:show or create the configuration'
    'help:show help'
    'version:show the version'
  )
  if (( CURRENT == 2 )); then
    _describe -t commands 'kcsecret command' commands
    return
  fi
  local -A opt_args
  case $words[2] in
    get|delete|rm) _kcsecret_names ;;
    set) (( CURRENT == 3 )) && _kcsecret_names ;;
    link)
      _arguments '(-E --environment)'{-E,--environment}'[environment]:environment:_kcsecret_environments' \
        '1:secret name:_kcsecret_names' '2:variable:' ;;
    add)
      _arguments '(-e --env)'{-e,--env}'[variable to export]:variable:' \
        '(-E --environment)'{-E,--environment}'[environment]:environment:_kcsecret_environments' \
        '1:secret name:_kcsecret_names' '2:variable:' ;;
    unlink)
      _arguments '(-E --environment)'{-E,--environment}'[environment]:environment:_kcsecret_environments' \
        '*:variable:_kcsecret_envrc_vars' ;;
    use) (( CURRENT == 3 )) && _kcsecret_environments ;;
    pause) _arguments '(-g --global)'{-g,--global}'[every project]' '1:duration (e.g. 30m, 2h, 1d):' ;;
    resume) _arguments '(-g --global --all)'{-g,--global}'[the global pause]' '(-g --global)--all[every pause]' ;;
    status) _arguments '(-E --environment)'{-E,--environment}'[environment]:environment:_kcsecret_environments' ;;
    export)
      _arguments -s \
        '(-E --environment)'{-E,--environment}'[environment]:environment:_kcsecret_environments' \
        '(-o --output)'{-o,--output}'[file to write, - for stdout]:file:_files' \
        '(-a --all)'{-a,--all}'[every variable, without asking]' \
        '--secrets-only[leave out plain .envrc variables]' \
        '--force[overwrite without asking]' \
        '*:variable:_kcsecret_envrc_vars' ;;
    run)
      local sep=${words[(I)--]}
      if (( sep && sep < CURRENT )); then
        words=("${(@)words[sep+1,-1]}"); (( CURRENT -= sep ))
        _normal  # complete the command after `--` as usual
      elif [[ $words[CURRENT-1] == (-E|--environment) ]]; then
        _kcsecret_environments
      else
        _message '-E ENV or ENV_VAR=NAME..., then -- and the command'
      fi ;;
    list|ls) _arguments '(-l --long)'{-l,--long}'[show dates]' ;;
    config) _arguments '--init[write a commented config file]' '--path[print the config path]' '--force[overwrite]' ;;
    import)
      _arguments -s \
        '(-f --file)'{-f,--file}'[the .env file]:file:_files' \
        '(-a --all)'{-a,--all}'[every variable, without asking]' \
        '(-t --template)'{-t,--template}'[name template]:template:' \
        '(-p --project)'{-p,--project}'[value of {project}]:project:' \
        '--strip[remove imported variables from the .env file]' \
        '--keep[keep them in the .env file]' \
        '--no-envrc[leave .envrc alone]' \
        '(-n --dry-run)'{-n,--dry-run}'[show what would happen]' \
        '(-E --environment)'{-E,--environment}'[environment to map them in]:environment:_kcsecret_environments' \
        '*:variable or .env file:{_kcsecret_dotenv_vars; _files -g ".env*(.) *.env(.)"}' ;;
  esac
}

if (( $+functions[compdef] )); then
  compdef _kcsecret kcsecret
  compdef _kcsecret_names ksecret
fi
