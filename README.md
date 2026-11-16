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

Flags: `--spec <source>` (repeatable) grounds the run in a PRD or ticket, `--fast` skips the debate, `--auto` skips the assumptions check-in, `--no-pr` stops at a committed branch.

### Working from a PRD or Linear issue

```
/agent-pipeline:pipeline --spec ENG-123 --spec ~/Downloads/rate-limits-prd.pdf
```

Subagents never see your conversation, and they can't call Linear or other connectors. So the orchestrator fetches each `--spec` once (a local file, a URL, or a Linear ID via your session's Linear connector) and saves a copy as Markdown in `.claude/pipeline/context/`, with an `INDEX.md` that gives every requirement a stable tag. Every agent reads that folder first.

- **Nothing is committed.** `.claude/pipeline/` is listed in your clone's `info/exclude`, not in `.gitignore`.
- **Everyone reads the same copy.** If the ticket is edited mid-run, the stages still agree.
- **Traceable.** The plan tags each acceptance criterion with its source requirement, tests carry the tags, the reviewer checks every requirement, and the PR body has a requirement → criterion → test table.
- **Linked, not closed.** A Linear ID goes into the branch name (`pipeline/eng-123-…`), so Linear links the PR. The PR says `Refs ENG-123`, not `Fixes`, so merging doesn't close the issue.
- **Worktrees:** git doesn't copy ignored files into a new worktree, so the orchestrator copies `context/` across from the main checkout, or fetches the specs again.
- Text in a spec that addresses an AI is treated as data. It's flagged, not obeyed.

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
