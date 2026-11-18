#!/usr/bin/env bash
# Tests for hooks/guard-git.sh. Run from the plugin root: bash tests/guard-git.test.sh
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/guard-git.sh"
P="$(mktemp -d)"; git -C "$P" init -q; git -C "$P" checkout -q -b pipeline/demo   # a pipeline run
O="$(mktemp -d)"; git -C "$O" init -q; git -C "$O" checkout -q -b main            # ordinary work
fail=0
check() { # check <want-exit> <agent_type> <cwd> <command>
  local got json
  json="$(python3 -c 'import json,sys; print(json.dumps({"agent_type":sys.argv[1],"cwd":sys.argv[2],"tool_name":"Bash","tool_input":{"command":sys.argv[3]}}))' "$2" "$3" "$4")"
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1; got=$?
  if [ "$got" = "$1" ]; then echo "ok   [$2] $4"; else echo "FAIL [$2] $4 (want $1, got $got)"; fail=1; fi
}
# Blocked on a pipeline branch (main session) ...
check 2 "" "$P" 'git commit --no-verify -m "feat: x"'
check 2 "" "$P" 'git commit -n -m "feat: x"'
check 2 "" "$P" 'git commit -anm wip'
check 2 "" "$P" 'git add . && git commit -nm "feat: x"'
check 2 "" "$P" 'git push --no-verify -u origin HEAD'
check 2 "" "$P" 'git -c core.hooksPath=/dev/null commit -m x'
check 2 "" "$P" 'git config core.hooksPath /tmp/none'
check 2 "" "$P" 'HUSKY=0 git commit -m x'
check 2 "" "$P" 'SKIP=eslint git commit -m x'
check 2 "" "$P" 'export HUSKY=0; git push'
check 2 "" "$P" 'git commit -m "x"; git commit --amend -n'
check 2 "" "$P" 'git commit "--no-verify" -m x'
check 2 "" "$P" 'git commit --no-verif -m x'
check 2 "" "$P" 'git push --no-veri origin HEAD'
check 2 "" "$P" 'LEFTHOOK=0 git commit -m x'
check 2 "" "$P" 'LEFTHOOK=false git push'
check 2 "" "$P" 'LEFTHOOK_EXCLUDE=lint,test git commit -m x'
check 2 "" "$P" 'export LEFTHOOK=0 && git commit -m x'
# ... and for pipeline subagents anywhere.
check 2 agent-pipeline:implementer "$O" 'git commit --no-verify -m x'
check 2 agent-pipeline:test-writer "$O" 'git commit -n -m x'
# Allowed.
check 0 "" "$P" 'git commit -m "feat: handle -n flag"'
check 0 "" "$P" 'git commit -m "feat: x" && git log -n 3'
check 0 "" "$P" 'git commit -m x
git log -n 3 --oneline'
check 0 "" "$P" 'git push -n origin HEAD'
check 0 "" "$P" 'git commit -m "docs: never use --no-verify or HUSKY=0"'
check 0 "" "$P" "git commit -m \"\$(cat <<'MSG'
fix: handle -n and core.hooksPath in docs

SKIP=x is mentioned here too
MSG
)\""
check 0 "" "$P" 'git config --get core.hooksPath'
check 0 "" "$P" 'git config core.hooksPath'
check 0 "" "$P" 'git log --oneline -n 5'
check 0 "" "$P" 'SKIP=1 make lint'
check 0 "" "$P" 'LEFTHOOK=0 pnpm test'
check 0 "" "$P" 'git commit -m "docs: LEFTHOOK=0 and --no-verif are blocked"'
check 0 "" "$P" 'pnpm test'
check 0 "" "$O" 'git commit --no-verify -m x'
check 0 some-other-agent "$O" 'git commit -n -m x'
rm -rf "$P" "$O"
exit $fail
