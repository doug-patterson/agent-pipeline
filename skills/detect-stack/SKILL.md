---
name: detect-stack
description: Detect a repository's language, package manager, and test/lint/typecheck commands and test-file globs, and write them to .claude/pipeline/config.json. Run as the first step of the agent-pipeline, or whenever pipeline config is missing or stale.
---
# Detect the repo's stack

Write `.claude/pipeline/config.json` at the repo root so every pipeline agent uses the same commands instead of guessing.

## 1. Gather evidence (read-only)

Check for these, from the repo root:
- **Manifests**: `package.json` (look at `scripts`, `devDependencies`, `packageManager`, `workspaces`), lockfiles (`pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`, `package-lock.json`), `pyproject.toml`, `setup.cfg`, `requirements*.txt`, `uv.lock`, `poetry.lock`, `go.mod`, `Cargo.toml`, `Gemfile`, `pom.xml`, `build.gradle*`, `*.csproj`, `mix.exs`, `composer.json`.
- **Task runners**: `Makefile`, `justfile`, `Taskfile.yml`, `tox.ini`, `noxfile.py`.
- **CI config**: `.github/workflows/*.yml`, `.gitlab-ci.yml`, `.circleci/config.yml`. CI is the most trustworthy source of the real test and lint commands.
- **Docs**: `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, `README.md` (look for "Development", "Testing" or "Running tests" sections).
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
  "default_branch": "main",
  "remote": "origin",
  "baseline": "312 passed, 0 failed",
  "notes": "Integration tests need Docker; unit tests do not."
}
```

Rules:
- Use `null` for any command that doesn't exist. Never invent one.
- `test_globs` must match every existing test file and fixture directory. The implement-phase guard hook uses these globs to block test edits, so missing a pattern weakens the guard. Include fixture directories (`testdata/`, `fixtures/`).
- Get `default_branch` from `git symbolic-ref refs/remotes/origin/HEAD` if it's set, else from `git branch`.

Also make sure `.claude/pipeline/` is ignored by git: add it to `.git/info/exclude`, not `.gitignore`, so the repo itself is untouched.

Report the config in a short table.
