#!/usr/bin/env bash
# PreToolUse guard: the agent-pipeline implementer may not edit test files.
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
    *) exit 0 ;;
  esac
fi

# Only the implementer is restricted. Plugin agents arrive as "agent-pipeline:implementer".
case "$agent_type" in
  implementer|*:implementer) ;;
  *) exit 0 ;;
esac

file_path="$(json_get '.tool_input.file_path // .tool_input.notebook_path' "d['tool_input'].get('file_path') or d['tool_input'].get('notebook_path')")"
cwd="$(json_get '.cwd' "d.get('cwd')")"
[ -z "$file_path" ] && exit 0
[ -z "$cwd" ] && cwd="$PWD"

canon() { # physical path, even if the tail doesn't exist yet (new files/dirs)
  local p="$1" tail=""
  while [ ! -d "$p" ] && [ "$p" != "/" ] && [ -n "$p" ]; do
    tail="/$(basename "$p")$tail"; p="$(dirname "$p")"
  done
  printf '%s%s' "$(cd "$p" 2>/dev/null && pwd -P)" "$tail"
}

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"
root="$(canon "$root")"
case "$file_path" in
  /*) abs="$file_path" ;;
  *)  abs="$cwd/$file_path" ;;
esac
abs="$(canon "$abs")"
rel="${abs#"$root"/}"

# Globs from the detected config, plus defaults that cover common conventions.
globs=""
config="$root/.claude/pipeline/config.json"
if [ -f "$config" ]; then
  json="$(cat "$config")"
  globs="$(json_get '.test_globs[]?' "d.get('test_globs') or []")"
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

# Iterate over lines without a subshell, so return codes survive.
old_ifs="$IFS"; IFS='
'
for g in $globs; do
  IFS="$old_ifs"
  [ -z "$g" ] && continue
  if matches "$rel" "$g"; then
    echo "agent-pipeline: the implementer may not edit test files ($rel matches '$g'). Tests are the spec. If a test is wrong, stop and report it to the orchestrator with the reason and the proposed change." >&2
    exit 2
  fi
done
IFS="$old_ifs"
exit 0
