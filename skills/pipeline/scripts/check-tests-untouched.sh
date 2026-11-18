#!/usr/bin/env bash
# Prove that a stage left every test file exactly as it found it.
# Usage:
#   check-tests-untouched.sh snapshot <snapshot-file> [repo-root]   record every test file and its content hash
#   check-tests-untouched.sh check    <snapshot-file> [repo-root]   compare the tree with the snapshot
# "Test file" means a tracked or untracked (not git-ignored) file matching config.json's test_globs or the
# built-in defaults, the same list the guard-tests.sh hook uses.
# check prints one line per difference and exits 1 if there is any:
#   TEST-CHANGED <file>    TEST-ADDED <file>    TEST-DELETED <file>
# Exit 0 = untouched, 1 = differences, 2 = usage or tool error.
# The pipeline takes a snapshot before each implementer and mutator stage and checks it afterwards. This
# catches writes the PreToolUse hooks can't see: an interpreter (python -c, node -e), a formatter or codemod
# run over the whole repo, a script the agent wrote.

set -f
mode="${1:-}"; snap="${2:-}"; root="${3:-$(git rev-parse --show-toplevel 2>/dev/null)}"
case "$mode" in snapshot|check) ;; *) echo "usage: check-tests-untouched.sh snapshot|check <snapshot-file> [repo-root]" >&2; exit 2 ;; esac
[ -n "$snap" ] && [ -n "$root" ] || { echo "usage: check-tests-untouched.sh snapshot|check <snapshot-file> [repo-root]" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-tests-untouched: needs python3" >&2; exit 2; }
case "$snap" in /*) ;; *) snap="$PWD/$snap" ;; esac
cd "$root" || exit 2

MODE="$mode" SNAP="$snap" python3 - <<'PY'
import fnmatch, hashlib, json, os, subprocess, sys

def match(path, g):
    if fnmatch.fnmatchcase(path, g):
        return True
    return g.startswith("**/") and fnmatch.fnmatchcase(path, g[3:])

cfg = {}
if os.path.exists(".claude/pipeline/config.json"):
    try:
        cfg = json.load(open(".claude/pipeline/config.json"))
    except ValueError:
        cfg = {}
globs = list(cfg.get("test_globs") or []) + [
    "**/test/**", "**/tests/**", "**/__tests__/**", "**/spec/**", "**/testdata/**", "**/fixtures/**",
    "**/*_test.*", "**/test_*.py", "**/*.test.*", "**/*.spec.*", "**/*Test.java", "**/*Tests.cs", "**/conftest.py"]

r = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], capture_output=True)
if r.returncode != 0:
    sys.stderr.write("check-tests-untouched: git ls-files failed\n"); sys.exit(2)
state = {}
for f in sorted(set(filter(None, r.stdout.decode("utf-8", "surrogateescape").split("\0")))):
    if f.startswith(".claude/pipeline/") or not any(match(f, g) for g in globs):
        continue
    try:
        with open(f, "rb") as fh:
            state[f] = hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        pass  # listed in the index but deleted from the tree: absent

if os.environ["MODE"] == "snapshot":
    os.makedirs(os.path.dirname(os.environ["SNAP"]) or ".", exist_ok=True)
    json.dump(state, open(os.environ["SNAP"], "w"), indent=0, sort_keys=True)
    print(f"snapshot: {len(state)} test files")
    sys.exit(0)

try:
    before = json.load(open(os.environ["SNAP"]))
except (OSError, ValueError):
    sys.stderr.write("check-tests-untouched: can't read snapshot\n"); sys.exit(2)
out = []
for f in sorted(set(before) | set(state)):
    if f not in state:
        out.append(f"TEST-DELETED {f}")
    elif f not in before:
        out.append(f"TEST-ADDED {f}")
    elif before[f] != state[f]:
        out.append(f"TEST-CHANGED {f}")
print("\n".join(out))
sys.exit(1 if out else 0)
PY
