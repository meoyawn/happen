// Modified Dart port of OpenAI Codex, Copyright 2025 OpenAI (Apache-2.0).
// Source: codex-rs/shell-command/src/{startup,shell_snapshot,shell_snapshot_capture}.rs
// Revision: ddd1812a51f4aded35c3ec5446672474d5cb546b. See ../../UPSTREAM.md.
// Native shell serialization is retained; Happen does not parse shell source.

const snapshotZshStartup = r'''if [[ -n "${ZDOTDIR-}" ]]; then
  rc="$ZDOTDIR/.zshrc"
elif [[ -n "${HOME-}" ]]; then
  rc="$HOME/.zshrc"
else
  rc=
fi
[[ -r "$rc" ]] && . "$rc"
''';

const snapshotBashStartup = r'''if [ -z "${BASH_ENV-}" ] && [ -n "${HOME-}" ] && [ -r "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi
''';

const snapshotPosixExpansion = r'''__codex_snapshot_expand_env() (
  set +u
  __codex_snapshot_getenv() {
    # Preserve the value separately from lookup status and its formatting newline.
    __codex_env_expanded=$(
      if command -v printenv >/dev/null 2>&1; then
        printenv "$1"
      elif [ "$1" = PATH ]; then
        [ "${PATH+x}" = x ] && printf '%s\n' "$PATH"
      else
        command -p printenv "$1"
      fi && printf '.'
    ) || return 1
    __codex_env_expanded=${__codex_env_expanded%?}
    __codex_env_expanded=${__codex_env_expanded%?}
  }
  __codex_env_file=$1
  case "$__codex_env_file" in
    '~/'*) __codex_env_file="${HOME-}/${__codex_env_file#*/}" ;;
    '${PATH%%:*}') __codex_env_file="${PATH%%:*}" ;;
    '${PATH%%:*}/'*) __codex_env_file="${PATH%%:*}/${__codex_env_file#*/}" ;;
    '${'*)
      __codex_env_body=${__codex_env_file#\$\{}
      case "$__codex_env_body" in
        *\}*)
          __codex_env_name=${__codex_env_body%%\}*}
          __codex_env_suffix=${__codex_env_body#*\}}
          case "$__codex_env_name" in
            *:-*)
              __codex_env_default=${__codex_env_name#*:-}
              __codex_env_name=${__codex_env_name%%:-*}
              __codex_env_has_default=1
              ;;
            *) __codex_env_has_default= ;;
          esac
          case "$__codex_env_name" in
            ''|[0-9]*|*[!A-Za-z0-9_]*) ;;
            *)
              case "$__codex_env_suffix" in
                ''|/*)
                  if __codex_snapshot_getenv "$__codex_env_name" 2>/dev/null &&
                    { [ -n "$__codex_env_expanded" ] || [ -z "$__codex_env_has_default" ]; }; then
                    __codex_env_file="$__codex_env_expanded$__codex_env_suffix"
                  elif [ -n "$__codex_env_has_default" ]; then
                    __codex_env_default=$(__codex_snapshot_expand_env "$__codex_env_default")
                    __codex_env_file="$__codex_env_default$__codex_env_suffix"
                  fi
                  ;;
              esac
              ;;
          esac
          ;;
      esac
      ;;
    '$'*)
      __codex_env_name=${__codex_env_file%%/*}
      __codex_env_name=${__codex_env_name#\$}
      case "$__codex_env_name" in
        ''|[0-9]*|*[!A-Za-z0-9_]*) ;;
        *)
          if __codex_snapshot_getenv "$__codex_env_name" 2>/dev/null; then
            if [ "$__codex_env_file" = "\$$__codex_env_name" ]; then
              __codex_env_file=$__codex_env_expanded
            else
              __codex_env_file="$__codex_env_expanded/${__codex_env_file#*/}"
            fi
          fi
          ;;
      esac
      ;;
  esac
  printf '%s' "$__codex_env_file"
)''';

const snapshotCommandHelper = r'''__codex_snapshot_command() {
  if command -v "$1" >/dev/null 2>&1; then
    "$@"
  else
    command -p "$@"
  fi
}''';

const snapshotEnvironment = r'''if command -v env >/dev/null 2>&1; then
  "env" -0
else
  # Resolve the fallback separately: Bash's command -p changes the utility's PATH.
  "$(PATH="$(command -p getconf PATH)" command -v env)" -0
fi
''';

const snapshotZshBody = r'''print '# Snapshot file'
print '# Unset all aliases to avoid conflicts with functions'
print 'unalias -a 2>/dev/null || true'
print '# Functions'
functions
print ''
SNAPSHOT_OPTIONS_BEGIN
SNAPSHOT_COMMAND_HELPER
setopt_count=$(setopt | __codex_snapshot_command wc -l | __codex_snapshot_command tr -d ' ')
print "# setopts $setopt_count"
setopt | __codex_snapshot_command sed 's/^/setopt /'
print ''
printf '\0'
alias_count=$(\alias -L | __codex_snapshot_command wc -l | __codex_snapshot_command tr -d ' ')
print "# aliases $alias_count"
SNAPSHOT_ZSH_ALIASES
print ''
SNAPSHOT_ALIASES_END
printf '\0'
SNAPSHOT_EXPORTS
printf '\0'
SNAPSHOT_ENVIRONMENT
''';

const snapshotBashBody = r'''echo '# Snapshot file'
echo '# Unset all aliases to avoid conflicts with functions'
echo 'unalias -a 2>/dev/null || true'
shopt -p || true
echo '# Functions'
declare -f
echo ''
SNAPSHOT_OPTIONS_BEGIN
SNAPSHOT_COMMAND_HELPER
bash_opts=$(set -o | __codex_snapshot_command awk '$2=="on"{print $1}')
bash_opt_count=$(printf '%s\n' "$bash_opts" | __codex_snapshot_command sed '/^$/d' | __codex_snapshot_command wc -l | __codex_snapshot_command tr -d ' ')
echo "# setopts $bash_opt_count"
if [ -n "$bash_opts" ]; then
  printf 'set -o %s\n' $bash_opts
fi
echo ''
printf '\0'
alias_count=$(\alias -p | __codex_snapshot_command wc -l | __codex_snapshot_command tr -d ' ')
echo "# aliases $alias_count"
\alias -p
echo ''
SNAPSHOT_ALIASES_END
printf '\0'
SNAPSHOT_EXPORTS
printf '\0'
SNAPSHOT_ENVIRONMENT
''';

const snapshotShStartup = r'''if [ -n "${ENV-}" ]; then
  __codex_env_file=$(__codex_snapshot_expand_env "$ENV")
  if [ -r "$__codex_env_file" ] && [ ! -d "$__codex_env_file" ]; then
    SNAPSHOT_STARTUP_ENVIRONMENT
    case "$__codex_env_file" in
      /*) . "$__codex_env_file" ;;
      *) . "./$__codex_env_file" ;;
    esac
  fi
  command unset __codex_env_file
fi
command unset -f __codex_snapshot_expand_env
''';

const snapshotShBody = r'''echo '# Snapshot file'
if [ -n "${BASH_VERSINFO-}" ]; then
  echo '# Bash-backed sh'
  shopt -p || true
fi
echo '# Unset all aliases to avoid conflicts with functions'
unalias -a 2>/dev/null || true
echo '# Functions'
if command -v typeset >/dev/null 2>&1; then
  typeset -f
elif command -v declare >/dev/null 2>&1; then
  declare -f
fi
echo ''
SNAPSHOT_OPTIONS_BEGIN
SNAPSHOT_COMMAND_HELPER
if set -o >/dev/null 2>&1; then
  sh_opts=$(set -o | __codex_snapshot_command awk '$2=="on"{print $1}')
  sh_opt_count=$(printf '%s\n' "$sh_opts" | __codex_snapshot_command sed '/^$/d' | __codex_snapshot_command wc -l | __codex_snapshot_command tr -d ' ')
  echo "# setopts $sh_opt_count"
  if [ -n "$sh_opts" ]; then
    printf 'set -o %s\n' $sh_opts
  fi
else
  echo '# setopts 0'
fi
echo ''
printf '\0'
if alias >/dev/null 2>&1; then
  alias_count=$(alias | __codex_snapshot_command wc -l | __codex_snapshot_command tr -d ' ')
  echo "# aliases $alias_count"
  alias
  echo ''
else
  echo '# aliases 0'
fi
SNAPSHOT_ALIASES_END
printf '\0'
SNAPSHOT_EXPORTS
printf '\0'
SNAPSHOT_DECLARATION_ENVIRONMENT
printf '\0'
SNAPSHOT_ENVIRONMENT
''';

