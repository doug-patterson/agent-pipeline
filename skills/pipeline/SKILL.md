---
name: pipeline
description: Run the full agent pipeline on a feature request in the current repo. Detect the stack, plan, debate designs, write failing tests (one model), implement (another model, barred from editing tests), review, and open a PR.
argument-hint: "<feature request> [--fast] [--auto] [--no-pr]"
disable-model-invocation: true
---
# Agent pipeline

Request: **$ARGUMENTS**

Flags in the request (strip them from the request text):
- `--fast`: skip the design debate and use the planner's recommended option.
- `--auto`: don't pause for the user to confirm the plan's assumptions.
- `--no-pr`: stop at a committed branch and print the PR description.

You are the orchestrator. Delegate each stage to the plugin subagent named below (subagent types `agent-pipeline:<name>`). Give each subagent a complete brief, because it sees nothing of this conversation. Verify each stage's result yourself before moving on; a subagent's report is not evidence. Keep the user informed with one short line per stage. Paths below are relative to the repo root, and `.claude/pipeline/` holds the working files.

## 0. Preflight
1. Confirm this is a git repo, and find the repo root. If the working tree has uncommitted changes, ask the user whether to continue on top of them or stop. Never stash or discard their work.
2. Record `BASE=$(git rev-parse HEAD)`. Create and switch to a branch `pipeline/<short-kebab-slug-of-request>`.
3. If `.claude/pipeline/config.json` is missing, run the `agent-pipeline:detect-stack` skill. Show the user the detected test/lint commands in one line.

## 1. Plan
Spawn `agent-pipeline:planner` with the request and the config path. Then read `.claude/pipeline/PLAN.md` yourself.
- Show the user the Goal, the Assumptions and the Acceptance criteria (compact).
- Unless `--auto`, ask the user once to confirm or correct the assumptions, using AskUserQuestion if it's available. Apply corrections to PLAN.md.

## 2. Debate (skip with `--fast` or when PLAN.md lists one option)
1. In a single message, spawn one `agent-pipeline:advocate` per design option in parallel. Assign each its option by letter and tell it to read PLAN.md.
2. Spawn `agent-pipeline:judge` with every advocate's full reply.
3. Read `.claude/pipeline/ADR.md` and tell the user the decision and the one-line rationale.

## 3. Tests first (red)
1. Spawn `agent-pipeline:test-writer`.
2. Verify it yourself: run the test command from config.json. The new tests must fail, for assertion or not-implemented reasons. Tests that passed at baseline must still pass. If not, send the failure back to the test-writer, at most twice.
3. Commit only the test-writer's changes: `test: <criteria summary>`. This red commit makes the TDD order visible in the history.

## 4. Implement (green)
1. Spawn `agent-pipeline:implementer`. A plugin hook blocks it from editing test files.
2. If it stops because it thinks a test is wrong: read the test and PLAN.md and decide. If the test is genuinely wrong, have `agent-pipeline:test-writer` fix it, noting the reason, and re-run the implementer. If you can't tell, ask the user.
3. Verify it yourself: run the test, lint and typecheck commands. All must pass. Then commit: `feat: <summary>`.

## 5. Review (at most 2 rounds)
1. Spawn `agent-pipeline:reviewer` with `BASE`. Don't give it your own opinion of the code.
2. If the result is CHANGES-REQUESTED, pass the must-fix items to the implementer, re-verify the tests, commit `fix: address review`, and review again. After two rounds, stop looping and list what remains open.

## 6. Ship
1. Build the PR body:
   - Summary (from PLAN Goal)
   - Design decision (ADR summary)
   - A criterion → test table
   - Commands run and their results
   - Open review items
   - Assumptions made

   `.claude/pipeline/` is not committed, so the PR body is where the plan and ADR live.
2. If `--no-pr`, or there's no remote, or `gh` isn't installed or authenticated: print the branch name and the PR body, and stop.
3. Otherwise: `git push -u <remote> HEAD`, then `gh pr create --base <default_branch> --title "<conventional title>" --body-file <tmp file>`. Report the PR URL.

## Final report
End with a short table: stage → outcome (option chosen, tests added, red→green counts, review verdict, PR URL or branch). Say plainly anything skipped, unverified or still failing.
