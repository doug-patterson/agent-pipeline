# agent-pipeline

A Claude Code plugin that takes a one-line feature request to a reviewed pull request, using a team of specialized subagents:

```
detect-stack → planner → advocates ×N ∥ → judge → test-writer (red) → implementer (green) → reviewer ⟲ → PR
                (opus)    (sonnet)         (opus)   (opus)               (sonnet)              (opus)
```

- **Works on any repo.** `detect-stack` reads manifests, CI config and docs to find the real test, lint and typecheck commands, and writes them to `.claude/pipeline/config.json`. That folder is git-excluded, so the repo stays untouched.
- **Debate, not one opinion.** One advocate per design option argues from the code, in parallel. A judge checks their claims and writes an ADR.
- **Tests-first with a different model.** The test-writer encodes the acceptance criteria as failing tests, which get their own commit. The implementer runs on a different model and has to make them pass.
- **Enforced, not requested.** A `PreToolUse` hook blocks the implementer from editing any test file. If it thinks a test is wrong, it has to stop and say why.
- **Independent review** by a model that didn't write the code, for up to two fix rounds.
- **Ships a PR** with the plan, the ADR and a criterion → test table in the body.

## Install

One command, from any directory:

```bash
claude plugin install agent-pipeline --marketplace doug-patterson/agent-pipeline
```

Or, inside Claude Code:

```
/plugin marketplace add doug-patterson/agent-pipeline
/plugin install agent-pipeline@agent-pipeline
```

## Use

From the root of any git repo, in Claude Code:

```
/agent-pipeline:pipeline add rate limiting to the /orders endpoint
```

Flags: `--fast` skips the debate, `--auto` skips the assumptions check-in, `--no-pr` stops at a committed branch.

To open a PR it needs `gh` installed and authenticated (`gh auth login`). Without it, the pipeline prints the branch and PR body instead.

## Requirements

- Claude Code 2.1.292+ (for `plugin install --marketplace`)
- git, and `jq` or `python3` for the guard hook (stock macOS has both)

## Develop

```bash
claude plugin validate . --strict
claude --plugin-dir .          # try it without installing
bash tests/guard-tests.test.sh # hook tests
```

## License

MIT
