#!/usr/bin/env bash
# Scan a pipeline diff for changes that switch the repo's checks off rather than satisfy them.
# Usage: check-weakening.sh <base> [repo-root]
# Compares <base> with the working tree (committed and uncommitted changes, and untracked files).
# Failing findings (exit 1):
#   SUPPRESSION <file>:<line>: <marker>   an added line in production code carries a suppression marker
#   CONFIG <file>                          a check-config file changed (lint, typecheck, test, coverage, hooks, CI)
#   CONFIG <file> [<section>]              a check section changed inside a mixed file
#                                          (pyproject.toml, setup.cfg, tox.ini, package.json)
# Reported for review, not failing:
#   TEST-SUPPRESSION <file>:<line>: <marker>   a suppression in a test file (hostile-input tests may need one)
#   CONFIG-ALLOWED <file>                      a check-config change listed in .claude/pipeline/allow-check-config.txt
# Exit 0 = no failing findings, 1 = failing findings, 2 = usage or tool error.
# The hook guard-checks.sh blocks the same things for the implementer and mutator as they edit;
# this scan also catches edits made through the shell, and by any other agent.

set -f
base="${1:-}"; root="${2:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$base" ] && [ -n "$root" ] || { echo "usage: check-weakening.sh <base> [repo-root]" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
cd "$root" || exit 2
git rev-parse --verify -q "$base^{commit}" >/dev/null || { echo "check-weakening: unknown base $base" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-weakening: needs python3" >&2; exit 2; }

patterns="$(grep -v -e '^# ' -e '^#$' -e '^[[:space:]]*$' "$here/suppression-markers.txt" | paste -sd'|' -)"

# Added lines with their new-side line numbers. Untracked files count as wholly added.
diff_text="$(git diff --unified=0 --no-color --no-ext-diff "$base" --)"
for f in $(git ls-files --others --exclude-standard); do
  diff_text="$diff_text
$(git diff --no-index --unified=0 --no-color -- /dev/null "$f" 2>/dev/null)"
done
# Pass the patterns through the environment: awk -v would eat the backslashes in \[ and \(.
hits="$(printf '%s\n' "$diff_text" | PAT="$patterns" awk '
  BEGIN { pat = ENVIRON["PAT"] }
  /^\+\+\+ / { f=$2; sub(/^b\//, "", f); next }
  /^@@ / { split($3, a, ","); n=substr(a[1], 2) + 0; next }
  /^\+/ { line=substr($0, 2); if (match(line, pat)) print f "\t" n "\t" substr(line, RSTART, RLENGTH); n++; next }
')" || { echo "check-weakening: awk failed" >&2; exit 2; }

changed="$( { git diff --name-only "$base" --; git ls-files --others --exclude-standard; } | sort -u)"

HITS="$hits" CHANGED="$changed" BASE="$base" GLOBS_FILE="$here/check-config-globs.txt" python3 - <<'PY'
import configparser, fnmatch, json, os, subprocess, sys

def globs_from(path):
    out = []
    for line in open(path):
        s = line.rstrip("\n")
        if not s.strip() or s.startswith("# ") or s == "#":
            continue
        out.append(s)
    return out

def match(path, g):
    # Shell-glob semantics as in the hook: * may cross '/', and **/x also matches x at the root.
    if fnmatch.fnmatchcase(path, g):
        return True
    return g.startswith("**/") and fnmatch.fnmatchcase(path, g[3:])

cfg = {}
if os.path.exists(".claude/pipeline/config.json"):
    try:
        cfg = json.load(open(".claude/pipeline/config.json"))
    except ValueError:
        cfg = {}
config_globs = globs_from(os.environ["GLOBS_FILE"]) + list(cfg.get("check_config_globs") or [])
test_globs = list(cfg.get("test_globs") or []) + [
    "**/test/**", "**/tests/**", "**/__tests__/**", "**/spec/**", "**/testdata/**", "**/fixtures/**",
    "**/*_test.*", "**/test_*.py", "**/*.test.*", "**/*.spec.*", "**/*Test.java", "**/*Tests.cs", "**/conftest.py"]
allowed = set()
if os.path.exists(".claude/pipeline/allow-check-config.txt"):
    allowed = {l.strip() for l in open(".claude/pipeline/allow-check-config.txt") if l.strip()}

failing, review = [], []
for line in filter(None, os.environ["HITS"].split("\n")):
    f, n, marker = line.split("\t", 2)
    if any(match(f, g) for g in test_globs):
        review.append(f"TEST-SUPPRESSION {f}:{n}: {marker}")
    else:
        failing.append(f"SUPPRESSION {f}:{n}: {marker}")

def old_text(path):
    r = subprocess.run(["git", "show", f"{os.environ['BASE']}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""

def new_text(path):
    try:
        return open(path).read()
    except OSError:
        return ""

def toml_sections(text):
    # Header-based, so it works without tomllib (Python < 3.11): the text of every [tool.<check>...] table.
    import re
    keys = ("ruff", "mypy", "coverage", "pytest", "pylint", "pyright", "black", "isort", "flake8", "bandit")
    out, cur = {}, None
    for line in (text or "").splitlines():
        m = re.match(r"^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$", line)
        if m:
            name = m.group(1).strip().strip('"')
            top = name.split(".")
            cur = f"tool.{top[1]}" if len(top) > 1 and top[0] == "tool" and top[1] in keys else None
            if cur:
                out.setdefault(cur, "")
                out[cur] += line.strip() + "\n"
            continue
        if cur and line.strip() and not line.strip().startswith("#"):
            out[cur] += line.strip() + "\n"
    return out

def ini_sections(text):
    p = configparser.RawConfigParser(strict=False)
    try:
        p.read_string(text or "")
    except configparser.Error:
        return None
    pick = lambda s: s in ("flake8", "pytest", "tool:pytest", "pycodestyle", "pydocstyle", "isort") \
        or s.startswith(("mypy", "coverage", "pylint"))
    return {s: json.dumps(dict(p.items(s)), sort_keys=True) for s in p.sections() if pick(s)}

def pkg_sections(text):
    try:
        d = json.loads(text or "{}")
    except ValueError:
        return None
    out = {k: json.dumps(d.get(k), sort_keys=True)
           for k in ("jest", "eslintConfig", "c8", "nyc", "lint-staged", "commitlint", "husky", "ava", "mocha")}
    for name, cmd in (d.get("scripts") or {}).items():
        if any(w in name for w in ("lint", "test", "typecheck", "type-check", "check", "coverage", "precommit", "prepush")):
            out[f"scripts.{name}"] = cmd
    return out

mixed = {"pyproject.toml": toml_sections, "setup.cfg": ini_sections, "tox.ini": ini_sections, "package.json": pkg_sections}

for f in filter(None, os.environ["CHANGED"].split("\n")):
    base_name = os.path.basename(f)
    if base_name in mixed:
        fn = mixed[base_name]
        a, b = fn(old_text(f)), fn(new_text(f))
        if a is None or b is None:
            review.append(f"CONFIG-UNPARSED {f}")
            continue
        for k in sorted(set(a) | set(b)):
            if a.get(k) != b.get(k):
                (review if f in allowed else failing).append(
                    f"{'CONFIG-ALLOWED' if f in allowed else 'CONFIG'} {f} [{k}]")
        continue
    if any(match(f, g) for g in config_globs):
        if f in allowed:
            review.append(f"CONFIG-ALLOWED {f}")
        else:
            failing.append(f"CONFIG {f}")

for l in failing + review:
    print(l)
sys.exit(1 if failing else 0)
PY
