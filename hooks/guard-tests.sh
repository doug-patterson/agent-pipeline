#!/usr/bin/env bash
# PreToolUse guard: the agent-pipeline implementer and mutator may not edit test files.
#   Edit/Write/MultiEdit/NotebookEdit: blocks any edit to a file that matches a test glob.
#   Bash: blocks the usual ways of writing to a test file from the shell: a redirect (`>`, `>>`) into one,
#     `tee`, `cp`, `mv`, `rm`, `touch`, `truncate`, `ln`, `install`, `rsync`, `patch`, `dd of=`,
#     `sed -i` / `perl -i`, and `git checkout|restore|rm|mv|apply|am` naming one.
#   This is a best-effort shell check. The pipeline also snapshots the test files before each implementer
#   and mutator stage and compares afterwards (skills/pipeline/scripts/check-tests-untouched.sh), which
#   catches writes made any other way (an interpreter, a formatter run over the whole repo).
# Exit 0 = allow. Exit 2 + stderr = block (Claude sees the reason).
# Works with bash 3.2 (stock macOS). Parses JSON with jq, falling back to python3.

set -f # globs below are patterns, never expand them against the filesystem
input="$(cat)"

json_get() { # json_get <jq-filter> <python-expr-on-d>; reads JSON from $json
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r "$1 // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c "import json,sys
d=json.load(sys.stdin)
try:
  v=$2
except Exception:
  v=None
if isinstance(v,list): print('\n'.join(map(str,v)))
elif v is not None: print(v)" 2>/dev/null
  else
    return 1
  fi
}

json="$input"
agent_type="$(json_get '.agent_type' "d.get('agent_type')")"
if [ $? -ne 0 ]; then
  # No JSON parser: fall back to a plain text match on the agent identity.
  case "$input" in
    *'"agent_type"'*implementer*) agent_type="implementer" ;;
    *'"agent_type"'*mutator*) agent_type="mutator" ;;
    *) exit 0 ;;
  esac
fi

# Only the implementer and mutator are restricted. Plugin agents arrive as "agent-pipeline:<name>".
case "$agent_type" in
  implementer|*:implementer|mutator|*:mutator) ;;
  *) exit 0 ;;
esac

tool="$(json_get '.tool_name' "d.get('tool_name')")"
cwd="$(json_get '.cwd' "d.get('cwd')")"
[ -z "$cwd" ] && cwd="$PWD"
if [ "$tool" = "Bash" ]; then
  command="$(json_get '.tool_input.command' "d['tool_input'].get('command')")"
  [ -z "$command" ] && exit 0
else
  file_path="$(json_get '.tool_input.file_path // .tool_input.notebook_path' "d['tool_input'].get('file_path') or d['tool_input'].get('notebook_path')")"
  [ -z "$file_path" ] && exit 0
fi

canon() { # physical path, even if the tail doesn't exist yet (new files/dirs)
  local p="$1" tail=""
  while [ ! -d "$p" ] && [ "$p" != "/" ] && [ -n "$p" ]; do
    tail="/$(basename "$p")$tail"; p="$(dirname "$p")"
  done
  printf '%s%s' "$(cd "$p" 2>/dev/null && pwd -P)" "$tail"
}

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"
root="$(canon "$root")"

# Globs from the detected config, plus defaults that cover common conventions.
globs=""
config="$root/.claude/pipeline/config.json"
if [ -f "$config" ]; then
  json="$(cat "$config")"
  globs="$(json_get '.test_globs[]?' "d.get('test_globs') or []")"
  json="$input"
fi
globs="$globs
**/test/**
**/tests/**
**/__tests__/**
**/spec/**
**/testdata/**
**/fixtures/**
**/*_test.*
**/test_*.py
**/*.test.*
**/*.spec.*
**/*Test.java
**/*Tests.cs
**/conftest.py"

matches() { # bash [[ == ]] lets * cross '/', so **/x also needs a root-level try
  local p="$1" g="$2"
  [[ "$p" == $g ]] && return 0
  case "$g" in
    '**/'*) [[ "$p" == ${g#'**/'} ]] && return 0 ;;
  esac
  return 1
}

hit_glob=""
is_test_path() { # is_test_path <path>; sets rel and hit_glob on a match
  local p="$1" abs g old_ifs
  case "$p" in
    /*) abs="$p" ;;
    *)  abs="$cwd/$p" ;;
  esac
  abs="$(canon "$abs")"
  rel="${abs#"$root"/}"
  [ "$rel" = "$abs" ] && return 1 # outside the repo
  old_ifs="$IFS"; IFS='
'
  for g in $globs; do
    IFS="$old_ifs"
    [ -z "$g" ] && continue
    if matches "$rel" "$g"; then hit_glob="$g"; return 0; fi
  done
  IFS="$old_ifs"
  return 1
}

block() { # block <rel> <glob> [how]
  echo "agent-pipeline: the $agent_type may not edit test files ($1 matches '$2'${3:+, via $3}). Tests are the spec. If a test is wrong, stop and report it to the orchestrator with the reason and the proposed change." >&2
  exit 2
}

if [ "$tool" != "Bash" ]; then
  is_test_path "$file_path" && block "$rel" "$hit_glob"
  exit 0
fi

# Bash: a token scan, bash 3.2 safe. Separators reset the per-command state.
writer=""; prev=""; redirect_next=0; saw_git=0
new_cmd() { writer=""; prev=""; redirect_next=0; saw_git=0; }
old_ifs="$IFS"; IFS=$' \t\n'
for tok in $command; do
  IFS="$old_ifs"
  ends_cmd=0
  case "$tok" in *';'|*'&&'|*'||'|*'|'|*')') ends_cmd=1 ;; esac
  # Strip surrounding quotes and a trailing separator.
  word="${tok%%[;&|)]*}"
  word="${word#[\"\']}"; word="${word%[\"\']}"
  # Redirects: `> f`, `>f`, `>>f`, `2>f`, `&>f`, `x>f`.
  if [ "$redirect_next" = 1 ]; then
    redirect_next=0
    [ -n "$word" ] && is_test_path "$word" && block "$rel" "$hit_glob" "a shell redirect"
  fi
  case "$word" in
    *'>') redirect_next=1 ;;
    *'>'*)
      target="${word##*>}"; target="${target#[\"\']}"
      case "$target" in ''|'&'*) ;; *) is_test_path "$target" && block "$rel" "$hit_glob" "a shell redirect" ;; esac
      ;;
  esac
  case "$word" in
    tee|*/tee|cp|*/cp|mv|*/mv|rm|*/rm|touch|truncate|ln|install|rsync|patch|unlink) writer="$word" ;;
    git|*/git) saw_git=1 ;;
    checkout|restore|apply|am) [ "$saw_git" = 1 ] && writer="git $word" ;;
    -i|-i?*|--in-place|--in-place=*|-pi|-pi?*) case "$prev" in sed|*/sed|gsed|perl|*/perl) writer="$prev -i" ;; esac ;;
    of=*) is_test_path "${word#of=}" && block "$rel" "$hit_glob" "dd" ;;
  esac
  # In a git command, rm and mv are subcommands.
  case "$word" in rm|mv) [ "$saw_git" = 1 ] && writer="git $word" ;; esac
  if [ -n "$writer" ] && [ "$word" != "$writer" ] && [ "$word" != "${writer#git }" ]; then
    case "$word" in
      -*|'') ;;
      *) is_test_path "$word" && block "$rel" "$hit_glob" "$writer" ;;
    esac
  fi
  prev="$word"
  [ "$ends_cmd" = 1 ] && new_cmd
done
IFS="$old_ifs"
exit 0
