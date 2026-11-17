#!/usr/bin/env bash
# Tests for hooks/guard-checks.sh and skills/pipeline/scripts/check-weakening.sh.
# Run from the plugin root: bash tests/guard-checks.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/guard-checks.sh"
SCAN="$ROOT/skills/pipeline/scripts/check-weakening.sh"
T="$(mktemp -d)"; git -C "$T" init -q; mkdir -p "$T/.claude/pipeline" "$T/src"
echo '{"check_config_globs":["tools/lint-rules/**"]}' > "$T/.claude/pipeline/config.json"
printf 'const a = 1; // eslint-disable-line\n' > "$T/src/has-one.ts"
fail=0
I=agent-pipeline:implementer

run() { # run <want-exit> <label> <json>
  local got
  printf '%s' "$3" | bash "$HOOK" >/dev/null 2>&1; got=$?
  if [ "$got" = "$1" ]; then echo "ok   $2"; else echo "FAIL $2 (want $1, got $got)"; fail=1; fi
}
edit() { # edit <want> <agent> <path> <old> <new>
  run "$1" "$2 Edit $3 +[$5]" "$(printf '{"agent_type":"%s","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"%s","new_string":"%s"}}' "$2" "$T" "$3" "$4" "$5")"
}
write() { # write <want> <agent> <path> <content>
  run "$1" "$2 Write $3" "$(printf '{"agent_type":"%s","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' "$2" "$T" "$3" "$4")"
}
tool() { # tool <want> <agent> <tool> <input-json>
  run "$1" "$2 $3 $4" "$(printf '{"agent_type":"%s","cwd":"%s","tool_name":"%s","tool_input":%s}' "$2" "$T" "$3" "$4")"
}

# Check-config files
edit 2 $I "$T/eslint.config.mjs" "a" "b"
edit 2 $I "$T/packages/x/tsconfig.json" "a" "b"
edit 2 $I "$T/eslint-suppressions.json" "a" "b"
edit 2 $I "$T/.github/workflows/check.yml" "a" "b"
edit 2 $I "$T/vitest.config.ts" "a" "b"
edit 2 $I "$T/.husky/pre-commit" "a" "b"
edit 2 $I "$T/tools/lint-rules/no-x.js" "a" "b"
edit 2 agent-pipeline:mutator "$T/.c8rc.json" "a" "b"
edit 0 agent-pipeline:test-writer "$T/vitest.config.ts" "a" "b"
edit 0 "" "$T/eslint.config.mjs" "a" "b"
edit 0 $I "$T/src/config.ts" "a" "b"

# Suppression markers
edit 2 $I "$T/src/a.ts" "x()" "// eslint-disable-next-line\\nx()"
edit 2 $I "$T/src/a.ts" "x()" "// @ts-expect-error\\nx()"
edit 2 $I "$T/src/a.py" "x()" "x()  # type: ignore"
edit 2 $I "$T/src/a.py" "x()" "x()  # noqa: E501"
edit 2 $I "$T/src/a.rs" "fn x()" "#[allow(dead_code)]\\nfn x()"
edit 0 $I "$T/src/a.ts" "// eslint-disable-line\\nx()" "// eslint-disable-line\\ny()"
edit 0 $I "$T/src/a.ts" "// @ts-ignore\\nx()" "x()"
edit 0 agent-pipeline:test-writer "$T/src/a.test.ts" "x()" "// @ts-expect-error\\nx()"
write 2 $I "$T/src/new.ts" "/* istanbul ignore next */ export const y = 1;"
write 0 $I "$T/src/has-one.ts" "const a = 2; // eslint-disable-line"
write 2 $I "$T/src/has-one.ts" "const a = 2; // eslint-disable-line\\n// @ts-nocheck"
run 2 "$I MultiEdit adds a marker" "$(printf '{"agent_type":"%s","cwd":"%s","tool_name":"MultiEdit","tool_input":{"file_path":"%s","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"c // nolint"}]}}' "$I" "$T" "$T/src/m.go")"

# Held-out tests (kept in <git-dir>/agent-pipeline/holdout/<slug>)
HO="$(git -C "$T" rev-parse --absolute-git-dir)/agent-pipeline/holdout/run"
tool 2 $I Read "{\"file_path\":\"$HO/src/a.holdout.test.ts\"}"
tool 2 $I Grep "{\"pattern\":\"expect\",\"path\":\"$HO\"}"
tool 2 $I Glob "{\"pattern\":\"**/agent-pipeline/holdout/**\"}"
tool 2 $I Bash "{\"command\":\"cat $HO/src/a.holdout.test.ts\"}"
tool 2 $I Write "{\"file_path\":\"$HO/x.ts\",\"content\":\"\"}"
tool 0 $I Read "{\"file_path\":\"$T/.claude/pipeline/PLAN.md\"}"
tool 0 $I Bash '{"command":"pnpm test"}'
# Once committed, held-out tests are ordinary tests: running one by name, or saying "holdout", is fine.
tool 0 agent-pipeline:mutator Bash '{"command":"pnpm vitest run src/orders/rate-limit.holdout.test.ts","description":"Run the holdout test"}'
tool 0 $I Read "{\"file_path\":\"$T/src/orders/rate-limit.holdout.test.ts\"}"
tool 0 agent-pipeline:test-writer Read "{\"file_path\":\"$HO/src/a.holdout.test.ts\"}"
tool 0 "" Bash "{\"command\":\"cat $HO/a\"}"

# Allowlisted check config
echo "packages/new/tsconfig.json" > "$T/.claude/pipeline/allow-check-config.txt"
edit 0 $I "$T/packages/new/tsconfig.json" "a" "b"
edit 2 $I "$T/packages/other/tsconfig.json" "a" "b"
rm "$T/.claude/pipeline/allow-check-config.txt"

# check-weakening.sh
git -C "$T" add -A >/dev/null; git -C "$T" -c user.email=t@t -c user.name=t commit -qm base
base="$(git -C "$T" rev-parse HEAD)"
scan() { # scan <want-exit> <label> <expect-substring>
  local o got; o="$(bash "$SCAN" "$base" "$T" 2>&1)"; got=$?
  if [ "$got" = "$1" ] && case "$o" in *"$3"*) true ;; *) false ;; esac; then echo "ok   scan $2"
  else echo "FAIL scan $2 (want $1 and '$3', got $got: $o)"; fail=1; fi
}
scan 0 "clean tree" ""
printf 'export const z = 1;\n// @ts-expect-error\nexport const w: number = "x";\n' > "$T/src/b.ts"
scan 1 "untracked file with a marker" "SUPPRESSION src/b.ts:2: @ts-expect-error"
rm "$T/src/b.ts"
printf 'const a = 1; // eslint-disable-line\nconst b = 2; # noqa\n' > "$T/src/has-one.ts"
scan 1 "added line in a tracked file" "SUPPRESSION src/has-one.ts:2: noqa"
git -C "$T" checkout -q -- src/has-one.ts
printf '#[allow(dead_code)]\nfn a() {}\n' > "$T/src/c.rs"
scan 1 "regex metacharacters in a marker" "SUPPRESSION src/c.rs:1: #[allow("
rm "$T/src/c.rs"
echo '{}' > "$T/tsconfig.json"
scan 1 "new check config" "CONFIG tsconfig.json"
git -C "$T" add tsconfig.json; git -C "$T" -c user.email=t@t -c user.name=t commit -qm cfg
scan 1 "committed check config" "CONFIG tsconfig.json"
base="$(git -C "$T" rev-parse HEAD)"
mkdir -p "$T/src/__tests__"
printf '// @ts-expect-error\nf("x");\n' > "$T/src/__tests__/hostile.test.ts"
scan 0 "suppression in a test file is reported, not failing" "TEST-SUPPRESSION src/__tests__/hostile.test.ts:1"
rm -rf "$T/src/__tests__"
printf '[project]\nname = "x"\ndependencies = ["a"]\n' > "$T/pyproject.toml"
printf '{"name":"x","scripts":{"lint":"eslint .","build":"tsc"}}\n' > "$T/package.json"
git -C "$T" add -A; git -C "$T" -c user.email=t@t -c user.name=t commit -qm mixed
base="$(git -C "$T" rev-parse HEAD)"
printf '[project]\nname = "x"\ndependencies = ["a", "b"]\n' > "$T/pyproject.toml"
printf '{"name":"x","scripts":{"lint":"eslint .","build":"tsc -b"},"dependencies":{"y":"1"}}\n' > "$T/package.json"
scan 0 "dependency and build changes in mixed files pass" ""
printf '[project]\nname = "x"\ndependencies = ["a"]\n[tool.mypy]\nignore_errors = true\n' > "$T/pyproject.toml"
scan 1 "a check section in pyproject.toml" "CONFIG pyproject.toml [tool.mypy]"
git -C "$T" checkout -q -- pyproject.toml
printf '{"name":"x","scripts":{"lint":"true","build":"tsc"}}\n' > "$T/package.json"
scan 1 "a lint script in package.json" "CONFIG package.json [scripts.lint]"
echo "package.json" > "$T/.claude/pipeline/allow-check-config.txt"
scan 0 "allowlisted change is reported, not failing" "CONFIG-ALLOWED package.json [scripts.lint]"

rm -rf "$T"
exit $fail
