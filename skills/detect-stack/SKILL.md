---
name: detect-stack
description: Detect a repository's language, package manager, test/lint/typecheck commands, test-file globs, how to run the app, and its commit and PR conventions, and write them to .claude/pipeline/config.json. Run as the first step of the agent-pipeline, or whenever pipeline config is missing or stale.
---
# Detect the repo's stack

Write `.claude/pipeline/config.json` at the repo root so every pipeline agent uses the same commands instead of guessing.

## 1. Gather evidence (read-only)

Check for these, from the repo root:
- **Manifests**: `package.json` (look at `scripts`, `devDependencies`, `packageManager`, `workspaces`), lockfiles (`pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`, `package-lock.json`), `pyproject.toml`, `setup.cfg`, `requirements*.txt`, `uv.lock`, `poetry.lock`, `go.mod`, `Cargo.toml`, `Gemfile`, `pom.xml`, `build.gradle*`, `*.csproj`, `mix.exs`, `composer.json`.
- **Task runners**: `Makefile`, `justfile`, `Taskfile.yml`, `tox.ini`, `noxfile.py`.
- **CI config**: `.github/workflows/*.yml`, `.gitlab-ci.yml`, `.circleci/config.yml`. CI is the most trustworthy source of the real test and lint commands.
- **Docs**: `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, `README.md` (look for "Development", "Testing" or "Running tests" sections).
- **Running the app**: the dev or start script, `Procfile`, `docker-compose*.yml`, `.claude/launch.json`, and the README's "Running locally" section: how to start the system, where it listens, and what it needs (a database, Docker, secrets).
- **Commit and PR conventions**: commitlint config (`commitlint.config.*`, `.commitlintrc*`, the `commitlint` key in `package.json`), `.github/pull_request_template.md` (also `.github/PULL_REQUEST_TEMPLATE/*.md`, `docs/pull_request_template.md`, `pull_request_template.md`), and the "before committing", "opening a PR" or "checklist" sections of `CONTRIBUTING.md`, `AGENTS.md` and `CLAUDE.md`.
- **Existing tests**: locate a few with Glob to learn the layout and naming (`**/*_test.go`, `**/test_*.py`, `**/*.test.ts`, `**/*.spec.*`, `tests/`, `__tests__/`, `spec/`).

## 2. Pick commands

Order of preference: what CI runs, then documented commands, then task-runner targets, then stack defaults. Prefer the repo's wrapper (`make test`, `pnpm test`) over a raw tool call. For monorepos, pick commands scoped to the package the task touches when that's clear; otherwise use the root command.

Run the test command once to confirm it works and record the baseline (passing, failing, or "no tests"). Don't install dependencies unless the test command fails because they're missing. If you install anything, say so in `notes`.

## 3. Write the config

```json
{
  "stack": "typescript/node (pnpm)",
  "install": "pnpm install",
  "test": "pnpm test",
  "test_single": "pnpm vitest run {file}",
  "lint": "pnpm lint",
  "typecheck": "pnpm tsc --noEmit",
  "test_globs": ["**/*.test.ts", "**/*.spec.ts", "**/__tests__/**", "tests/**", "test/**"],
  "property_lib": "fast-check",
  "default_branch": "main",
  "config_version": 2,
  "run": {
    "setup": "docker compose up -d postgres redis",
    "start": "pnpm dev",
    "ready": "http://localhost:3030/health",
    "base_url": "http://localhost:3030",
    "stop": null,
    "timeout_s": 120,
    "notes": "Needs Docker. Seed with pnpm seed for a user to log in as."
  },
  "check_config_globs": ["tools/eslint-rules/**"],
  "commit_convention": {
    "source": "commitlint.config.mjs",
    "format": "type(scope): subject",
    "types": ["feat", "fix", "test", "refactor", "docs", "chore"],
    "scope": "optional",
    "subject_case": "lower-case first word",
    "max_header_length": 100,
    "example": "feat(orders): rate-limit order creation"
  },
  "pr_template": ".github/pull_request_template.md",
  "pr_rules": [
    "Commit regenerated files under generated/ if migrate or compile changed them (AGENTS.md:180)",
    "List the feature gates the change ships behind as `Gate: <id>` lines (AGENTS.md:192)"
  ],
  "remote": "origin",
  "baseline": "312 passed, 0 failed",
  "notes": "Integration tests need Docker; unit tests do not."
}
```

Rules:
- Use `null` for any command that doesn't exist. Never invent one.
- `test_globs` must match every existing test file and fixture directory. The implement-phase guard hook uses these globs to block test edits, so missing a pattern weakens the guard. Include fixture directories (`testdata/`, `fixtures/`).
- `property_lib` is the property-based testing library the repo already depends on (fast-check, Hypothesis, proptest, quickcheck, jqwik, rapid, gopter, …), or `null`. Look in the manifests and lockfiles; don't install one.
- `config_version` is `2`. The pipeline re-runs this skill when it's missing or lower, so keep any value you can't detect from the older file rather than dropping it.
- `run` says how to start the system for the evaluator: a command that starts it in the foreground (`start`), how to tell it's ready (`ready`: a URL or a command), and anything that must run first (`setup`). Use `null` for the whole block when the repo is a library or has nothing to run, and put what's missing (Docker, a secret, a device) in `notes` when it can't run here. Don't start it now.
- `check_config_globs` lists repo-specific files that configure checks beyond the plugin's built-in list (custom lint rules, a coverage thresholds file, a shared config package). Use `[]` if there are none.
- `commit_convention` describes what the repo's commit hook enforces, from its config, not from guesses. Use `null` if nothing enforces one.
- `pr_template` is the path of the PR template GitHub would use for a new PR, or `null`.
- `pr_rules` lists the repo's own written requirements for a commit or PR that the pipeline must meet, each with the `file:line` that states it. Only rules a document states; at most about ten, the ones a PR fails review or CI without.
- Get `default_branch` from `git symbolic-ref refs/remotes/origin/HEAD` if it's set, else from `git branch`.

Also make sure `.claude/pipeline/` is ignored by git: add it to the file that `git rev-parse --git-path info/exclude` names, if it isn't there already. Don't use `.gitignore`, so the repo itself is untouched. Don't hard-code `.git/info/exclude`; in a worktree, `.git` is a file.

Report the config in a short table.
