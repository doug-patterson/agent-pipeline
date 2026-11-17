#!/usr/bin/env bash
# PreToolUse guard: the agent-pipeline implementer and mutator may not switch the repo's checks off,
# and may not look at the held-out tests.
#   Edit/Write/MultiEdit/NotebookEdit: blocks edits to check-config files (lint, typecheck, test,
#     coverage, git-hook and CI config) and edits that add a suppression marker
#     (eslint-disable, @ts-expect-error, # noqa, # type: ignore, ...), and any write under the holdout folder.
#   Read/Grep/Glob: blocks access to the held-out tests (<git-common-dir>/agent-pipeline/holdout).
#   Bash: blocks commands that name that folder.
# A check-config path listed in .claude/pipeline/allow-check-config.txt (written by the orchestrator
# when the plan calls for it) may be edited.
# Exit 0 = allow. Exit 2 + stderr = block (Claude sees the reason).
# Works with bash 3.2 (stock macOS). Parses JSON with jq, falling back to python3.

set -f # globs below are patterns, never expand them against the filesystem
input="$(cat)"
here="$(cd "$(dirname "$0")" && pwd)"
lists="$here/../skills/pipeline/scripts"

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
if ! agent_type="$(json_get '.agent_type' "d.get('agent_type')")"; then
  # No JSON parser: only the holdout check can run, as a plain text match.
  case "$input" in
    *'"agent_type"'*implementer*|*'"agent_type"'*mutator*)
      case "$input" in *agent-pipeline/holdout*)
        echo "agent-pipeline: the held-out tests are off limits to this agent." >&2; exit 2 ;;
      esac ;;
  esac
  exit 0
fi

case "$agent_type" in
  implementer|*:implementer|mutator|*:mutator) ;;
  *) exit 0 ;;
esac

block() { echo "agent-pipeline: $1" >&2; exit 2; }
HOLDOUT_MSG="the held-out tests (agent-pipeline/holdout) are off limits to the $agent_type. The orchestrator runs them after you finish; work from PLAN.md and the visible tests."

tool="$(json_get '.tool_name' "d.get('tool_name')")"
tool_input="$(json_get '.tool_input | tostring' "json.dumps(d.get('tool_input'))")"

case "$tool" in
  Bash)
    command="$(json_get '.tool_input.command' "d['tool_input'].get('command')")"
    case "$command" in *agent-pipeline/holdout*) block "$HOLDOUT_MSG" ;; esac
    exit 0 ;;
  Read|Grep|Glob|LS)
    case "$tool_input" in *agent-pipeline/holdout*) block "$HOLDOUT_MSG" ;; esac
    exit 0 ;;
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

case "$tool_input" in *agent-pipeline/holdout*) block "$HOLDOUT_MSG" ;; esac

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

# 1. Check-config files: the plugin's list plus check_config_globs from the detected config.
globs="$(grep -v -e '^# ' -e '^#$' -e '^[[:space:]]*$' "$lists/check-config-globs.txt" 2>/dev/null)"
config="$root/.claude/pipeline/config.json"
if [ -f "$config" ]; then
  json="$(cat "$config")"
  globs="$globs
$(json_get '.check_config_globs[]?' "d.get('check_config_globs') or []")"
  json="$input"
fi
allow="$root/.claude/pipeline/allow-check-config.txt"
allowed=0
if [ -f "$allow" ] && grep -Fqx -- "$rel" "$allow"; then allowed=1; fi
matches() { # bash [[ == ]] lets * cross '/', so **/x also needs a root-level try
  local p="$1" g="$2"
  [[ "$p" == $g ]] && return 0
  case "$g" in '**/'*) [[ "$p" == ${g#'**/'} ]] && return 0 ;; esac
  return 1
}
old_ifs="$IFS"; IFS='
'
for g in $globs; do
  IFS="$old_ifs"
  [ -z "$g" ] && continue
  if [ "$allowed" = 0 ] && matches "$rel" "$g"; then
    block "the $agent_type may not edit check configuration ($rel matches '$g'). Lint, typecheck, test, coverage, hook and CI settings are the bar the change is measured against. If one is genuinely wrong, stop and report it to the orchestrator with the reason and the proposed change."
  fi
done
IFS="$old_ifs"

# 2. Suppression markers: block an edit that leaves more of them than it found.
patterns="$(grep -v -e '^# ' -e '^#$' -e '^[[:space:]]*$' "$lists/suppression-markers.txt" 2>/dev/null)"
[ -z "$patterns" ] && exit 0
count() { printf '%s' "$1" | grep -E -o -e "$(printf '%s' "$patterns" | paste -sd'|' -)" 2>/dev/null | wc -l | tr -d ' '; }
found() { printf '%s' "$1" | grep -E -o -e "$(printf '%s' "$patterns" | paste -sd'|' -)" 2>/dev/null | sort -u | paste -sd',' -; }

case "$tool" in
  Edit)
    new="$(json_get '.tool_input.new_string' "d['tool_input'].get('new_string')")"
    old="$(json_get '.tool_input.old_string' "d['tool_input'].get('old_string')")" ;;
  MultiEdit)
    new="$(json_get '[.tool_input.edits[]?.new_string] | join("\n")' "'\n'.join(e.get('new_string','') for e in d['tool_input'].get('edits',[]))")"
    old="$(json_get '[.tool_input.edits[]?.old_string] | join("\n")' "'\n'.join(e.get('old_string','') for e in d['tool_input'].get('edits',[]))")" ;;
  Write)
    new="$(json_get '.tool_input.content' "d['tool_input'].get('content')")"
    old="$(cat "$abs" 2>/dev/null)" ;;
  NotebookEdit)
    new="$(json_get '.tool_input.new_source' "d['tool_input'].get('new_source')")"
    old="" ;;
esac
n_new="$(count "$new")"; n_old="$(count "$old")"
if [ "${n_new:-0}" -gt "${n_old:-0}" ]; then
  block "the $agent_type may not add check suppressions ($(found "$new") in $rel). Fix the code so the lint, typecheck or coverage check passes. If a suppression is genuinely the right answer, stop and report it to the orchestrator with the reason."
fi
exit 0
