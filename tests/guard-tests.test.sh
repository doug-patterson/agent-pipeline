#!/usr/bin/env bash
# Tests for hooks/guard-tests.sh. Run from the plugin root: bash tests/guard-tests.test.sh
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/guard-tests.sh"
T="$(mktemp -d)"; git -C "$T" init -q; mkdir -p "$T/.claude/pipeline"
echo '{"test_globs":["checks/**"]}' > "$T/.claude/pipeline/config.json"
fail=0
check() { # check <want-exit> <agent_type> <path>
  local got
  printf '{"agent_type":"%s","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$2" "$T" "$3" \
    | bash "$HOOK" >/dev/null 2>&1; got=$?
  if [ "$got" = "$1" ]; then echo "ok   $2 $3"; else echo "FAIL $2 $3 (want $1, got $got)"; fail=1; fi
}
I=agent-pipeline:implementer
check 0 $I "$T/src/app.ts"
check 2 $I "$T/src/app.test.ts"
check 2 $I "$T/src/app.spec.js"
check 2 $I "$T/tests/test_x.py"
check 2 $I "$T/test_root.py"
check 2 $I "$T/pkg/foo_test.go"
check 2 $I "$T/checks/a/b.sh"
check 2 $I "src/__tests__/rel.ts"
check 0 $I "$T/new/dir/x.py"
check 0 agent-pipeline:test-writer "$T/src/app.test.ts"
check 0 "" "$T/src/app.test.ts"
rm -rf "$T"
exit $fail
