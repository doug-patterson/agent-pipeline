#!/usr/bin/env bash
# PreToolUse guard (Bash): during an agent-pipeline run, never bypass the repo's git hooks.
# Applies to agent-pipeline subagents, and to the main session while the repo is on a pipeline/* branch.
# Blocks: --no-verify on any git command, `git commit -n`, core.hooksPath overrides,
# and hook-silencing env vars (HUSKY=0, HUSKY_SKIP_HOOKS, SKIP= for pre-commit) on git commit/push.
# Exit 0 = allow. Exit 2 + stderr = block (Claude sees the reason).
# Works with bash 3.2 (stock macOS). Parses JSON with jq, falling back to python3.

set -f # tokens below are words, never expand them against the filesystem
input="$(cat)"

json_get() { # json_get <jq-filter> <python-expr-on-d>; reads JSON from $input
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$input" | python3 -c "import json,sys
d=json.load(sys.stdin)
try:
  v=$2
except Exception:
  v=None
if v is not None: print(v)" 2>/dev/null
  else
    return 1
  fi
}

parsed=1
if cmd="$(json_get '.tool_input.command' "d['tool_input'].get('command')")"; then
  agent_type="$(json_get '.agent_type' "d.get('agent_type')")"
  cwd="$(json_get '.cwd' "d.get('cwd')")"
else
  # No JSON parser: fall back to the raw text (see the substring check below).
  parsed=0; cmd="$input"; agent_type=""; cwd=""
  case "$input" in *'"agent_type"'*agent-pipeline:*) agent_type="agent-pipeline:?" ;; esac
fi
[ -z "$cmd" ] && exit 0
[ -z "$cwd" ] && cwd="$PWD"

# Is this a pipeline context?
in_scope=0
case "$agent_type" in agent-pipeline:*) in_scope=1 ;; esac
if [ "$in_scope" = 0 ]; then
  branch="$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null)"
  case "$branch" in pipeline/*) in_scope=1 ;; esac
fi
[ "$in_scope" = 1 ] || exit 0

# Cheap exit: nothing git-related.
case "$cmd" in *git*) ;; *) exit 0 ;; esac

block() {
  echo "agent-pipeline: don't bypass the repo's hooks or checks ($1). If a hook or check fails, find and fix the cause, then run the command again without the bypass. If you can't fix it, stop and report it. (A person who really needs the bypass can run the command themselves in a terminal.)" >&2
  exit 2
}


if [ "$parsed" = 0 ]; then
  # No JSON parser: a crude substring check on the raw text, so the obvious bypasses are still caught.
  case "$cmd" in
    *--no-verify*) block "--no-verify" ;;
    *core.hooksPath=*|*HUSKY=0*) block "hook override" ;;
  esac
  exit 0
fi

# Token scan, bash 3.2 safe. Separators reset the per-command state.
saw_git=0; in_commit=0; commit_or_push=0; env_bypass=""; hooks_key=0; quote=""
HP='[cC][oO][rR][eE].[hH][oO][oO][kK][sS][pP][aA][tT][hH]'
new_cmd() { saw_git=0; in_commit=0; hooks_key=0; }
old_ifs="$IFS"; IFS=$' \t\n'
for tok in $cmd; do
  IFS="$old_ifs"
  # A separator at the end of a word (`-n;`, `x"&&`) means a new command starts after it.
  ends_cmd=0
  case "$tok" in *';'|*'&&'|*'||'|*'|'|*')') ends_cmd=1 ;; esac
  # Skip quoted text that spans several words (commit messages, heredoc bodies): it's an argument, not a flag.
  if [ -n "$quote" ]; then
    case "$tok" in *"$quote"|*"$quote"[\;\&\|\)]*) quote=""; [ "$ends_cmd" = 1 ] && new_cmd ;; esac
    continue
  fi
  case "$tok" in
    \"*|\'*)
      q="${tok:0:1}"; rest="${tok:1}"
      case "$rest" in
        *"$q"|*"$q"[\;\&\|\)]*) tok="${rest%"$q"*}" ;; # one quoted word: look inside it
        *) quote="$q"; continue ;;
      esac
      ;;
  esac
  word="${tok%%[;&|)]*}"
  # `git config core.hooksPath <value>` sets it; reading or unsetting it is fine.
  if [ "$hooks_key" = 1 ]; then
    hooks_key=0
    case "$word" in ''|-*) ;; *) block "core.hooksPath override" ;; esac
  fi
  case "$word" in
    *$HP=*) block "core.hooksPath override" ;;
    *$HP) [ "$ends_cmd" = 0 ] && hooks_key=1 ;;
    --no-verify|--no-verify=*) block "--no-verify" ;;
    HUSKY=0|HUSKY=false|HUSKY_SKIP_HOOKS=*) env_bypass="$word" ;;
    SKIP=?*) env_bypass="$word" ;;
    git|*/git) saw_git=1; in_commit=0 ;;
    commit) [ "$saw_git" = 1 ] && { in_commit=1; commit_or_push=1; } ;;
    push) [ "$saw_git" = 1 ] && commit_or_push=1 ;;
    -*n*)
      # git commit -n / -an / -nm msg: argument-less short flags, optionally ending in one that takes an argument.
      if [ "$in_commit" = 1 ]; then
        flags="${word%[mFCct]}"
        case "$flags" in
          --*) ;;
          -*[!aeinopqsv]*) ;;
          *n*) block "git commit $word skips the pre-commit and commit-msg hooks" ;;
        esac
      fi
      ;;
  esac
  [ "$ends_cmd" = 1 ] && new_cmd
done
IFS="$old_ifs"

if [ -n "$env_bypass" ] && [ "$commit_or_push" = 1 ]; then
  block "$env_bypass silences hooks"
fi
exit 0
