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
check 2 agent-pipeline:mutator "$T/src/app.test.ts"
check 0 agent-pipeline:mutator "$T/src/app.ts"
check 0 agent-pipeline:test-writer "$T/src/app.test.ts"
check 0 "" "$T/src/app.test.ts"

# Bash: writing a test file from the shell
sh() { # sh <want-exit> <agent_type> <command>
  local got json
  json="$(python3 -c 'import json,sys; print(json.dumps({"agent_type":sys.argv[1],"cwd":sys.argv[2],"tool_name":"Bash","tool_input":{"command":sys.argv[3]}}))' "$2" "$T" "$3")"
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1; got=$?
  if [ "$got" = "$1" ]; then echo "ok   $2 \$ $3"; else echo "FAIL $2 \$ $3 (want $1, got $got)"; fail=1; fi
}
sh 2 $I "sed -i 's/a/b/' src/app.test.ts"
sh 2 $I "sed -i '' -e 's/a/b/' src/app.test.ts"
sh 2 $I "perl -pi -e 's/a/b/' tests/test_x.py"
sh 2 $I "cat > tests/test_x.py <<'EOF'
assert True
EOF"
sh 2 $I "echo x >> src/app.spec.js"
sh 2 $I "echo x>src/app.spec.js"
sh 2 $I "printf x | tee src/__tests__/a.ts"
sh 2 $I "cp /tmp/x src/app.test.ts"
sh 2 $I "mv src/app.test.ts src/app.ts"
sh 2 $I "rm -f pkg/foo_test.go"
sh 2 $I "git checkout -- src/app.test.ts"
sh 2 $I "git restore src/app.test.ts"
sh 2 $I "git rm src/app.test.ts"
sh 2 $I "pnpm lint && echo x > checks/a.sh"
sh 2 $I "truncate -s 0 $T/src/app.test.ts"
sh 2 agent-pipeline:mutator "git checkout -- src/app.test.ts"
sh 0 $I "cat src/app.test.ts"
sh 0 $I "pnpm vitest run src/app.test.ts > .claude/pipeline/logs/t.log 2>&1"
sh 0 $I "pnpm test 2>&1 | tee .claude/pipeline/logs/test-1.log"
sh 0 $I "grep -rn expect tests/ > /tmp/out.txt"
sh 0 $I "sed -n 1,20p src/app.test.ts"
sh 0 $I "sed -i 's/a/b/' src/app.ts"
sh 0 $I "git checkout -- src/app.ts"
sh 0 $I "cp src/app.ts /tmp/app.ts.bak"
sh 0 agent-pipeline:mutator "git checkout -- src/orders/rate-limit.ts"
sh 0 agent-pipeline:test-writer "sed -i 's/a/b/' src/app.test.ts"
sh 0 "" "rm src/app.test.ts"

# check-tests-untouched.sh: the snapshot catches what the hook can't see
SNAPSH="$(cd "$(dirname "$0")/.." && pwd)/skills/pipeline/scripts/check-tests-untouched.sh"
mkdir -p "$T/src"; echo 'test("a")' > "$T/src/app.test.ts"; echo 'x' > "$T/src/app.ts"
git -C "$T" add -A >/dev/null; git -C "$T" -c user.email=t@t -c user.name=t commit -qm base
snapcheck() { # snapcheck <want-exit> <label> <expect-substring>
  local o got; o="$(bash "$SNAPSH" check "$T/.claude/pipeline/logs/s.json" "$T" 2>&1)"; got=$?
  if [ "$got" = "$1" ] && case "$o" in *"$3"*) true ;; *) false ;; esac; then echo "ok   snapshot $2"
  else echo "FAIL snapshot $2 (want $1 and '$3', got $got: $o)"; fail=1; fi
}
bash "$SNAPSH" snapshot "$T/.claude/pipeline/logs/s.json" "$T" >/dev/null
echo 'y' > "$T/src/app.ts"
snapcheck 0 "production change only" ""
python3 -c "open('$T/src/app.test.ts','a').write('x')"
snapcheck 1 "test changed by an interpreter" "TEST-CHANGED src/app.test.ts"
git -C "$T" checkout -q -- src/app.test.ts
echo 'test("b")' > "$T/src/b.test.ts"
snapcheck 1 "test added" "TEST-ADDED src/b.test.ts"
rm "$T/src/b.test.ts" "$T/src/app.test.ts"
snapcheck 1 "test deleted" "TEST-DELETED src/app.test.ts"
git -C "$T" checkout -q -- src/app.test.ts
echo 'test("uncommitted fix")' >> "$T/src/app.test.ts"
bash "$SNAPSH" snapshot "$T/.claude/pipeline/logs/s.json" "$T" >/dev/null
snapcheck 0 "an uncommitted test change made before the snapshot" ""
rm -rf "$T"
exit $fail
