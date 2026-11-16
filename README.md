# agent-pipeline

A Claude Code plugin that takes a one-line feature request to a reviewed pull request, using a team of specialized subagents:

```
detect-stack → planner → property-finder → advocates ×N ∥ → judge → test-writer (red) → implementer (green) → mutator → reviewer ⟲ → PR
               (opus)    (sonnet)          (sonnet)         (opus)  (opus)              (sonnet)              (sonnet)  (opus)
```

- **Works on any repo.** `detect-stack` reads manifests, CI config and docs to find the real test, lint and typecheck commands, and writes them to `.claude/pipeline/config.json`. That folder is git-excluded, so the repo stays untouched.
- **Debate, not one opinion.** One advocate per design option argues from the code, in parallel. A judge checks their claims and writes an ADR.
- **Tests-first with a different model.** The test-writer encodes the acceptance criteria as failing tests, which get their own commit. The implementer runs on a different model and has to make them pass.
- **Enforced, not requested.** A `PreToolUse` hook blocks the implementer from editing any test file. If it thinks a test is wrong, it has to stop and say why.
- **Properties, not just examples.** The planner and a blind second agent list what must *always* hold (round-trips, nothing lost, rejected means no effect, …), and the test-writer encodes those as property-based tests.
- **Tests that can fail.** After green, a mutator breaks the code once per criterion and property and checks that a test catches it.
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

### Flags

Put flags anywhere in the request. Combine them freely.

| Flag | What it does | Use it when |
|---|---|---|
| `--spec <source>` | Grounds the run in a requirements source: a local file (PRD, design doc, exported ticket; PDF and DOCX are converted), a URL, or a Linear issue ID or URL. Repeat it for several sources. The request text can then be empty. See [Working from a PRD or Linear issue](#working-from-a-prd-or-linear-issue). | The work comes from a ticket or PRD. Prefer this to pasting the text into chat, because subagents never see the conversation. |
| `--fast` | Skips the design debate (advocates and judge) and uses the planner's recommended option. Also skips the blind `property-finder`; the planner's own property pass and the mutation check still run. | The design is obvious, or the change is small. |
| `--auto` | Doesn't stop to confirm the plan's assumptions. Properties that need a product decision become open gaps instead of tests. | You trust the request as written, or you're running unattended. |
| `--no-properties` | Skips property discovery, property tests, the mutation check and the `INVARIANTS.md` update. Existing invariants are still read and reviewed against. | Wording, styling or config changes with no logic. (The planner also exempts these on its own.) |
| `--draft` | Pushes the branch and opens the PR as a draft. Without it, the PR is opened ready for review. | You want CI to run and teammates to see the work before it asks for review. |
| `--no-pr` | Stops at a committed local branch and prints the PR description. Nothing is pushed. Takes precedence over `--draft`. | You want to look before anything leaves your machine. |

Examples:

```
/agent-pipeline:pipeline --fast fix the off-by-one in pagination on /orders
/agent-pipeline:pipeline --spec ENG-123 --no-pr
/agent-pipeline:pipeline --spec ENG-123 --draft
/agent-pipeline:pipeline --auto --no-properties update the footer copyright year
```

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

### Properties, invariants and the mutation check

Passing tests only show that the cases someone wrote down work. The pipeline also looks for what must hold for **every** input and order of operations, and checks that the tests would actually catch a broken implementation.

1. **Discovery.** The planner reads `PROPERTY-DISCOVERY.md`, works through its checklist of property patterns (state-machine model, nothing lost, round-trip, rejected means no effect, consistency between two views, …) and lists candidates in `PLAN.md`. Then `property-finder` makes its own list without seeing the planner's, and the orchestrator merges the two. Each candidate is marked **test**, **covered** (by a named existing test), **reject** (with a reason) or **ask**. An **ask** depends on a product decision, so it goes to you in the assumptions check-in rather than being guessed.
2. **Property tests.** The test-writer writes a property-based test for each **test** row, using the library `detect-stack` found (fast-check, Hypothesis, proptest, jqwik, …). If the repo has none, the plan proposes adding one, and you can decline it at the check-in.
3. **Mutation check.** After the tests go green, the `mutator` breaks the code once per criterion and property (flip a condition, drop a field, skip a write), checks that a test fails, and restores the code. If a mutation survives, the test-writer adds a test that catches it.
4. **No weakened tests.** The orchestrator rejects test diffs that delete tests or assertions, add skip/only markers, or lower property run counts. A hook stops the implementer and the mutator from editing tests at all.
5. **The registry grows.** After the run, lasting properties are added to `INVARIANTS.md` with the tests that guard them, so the next run starts from them. The pipeline adds rows but never removes or weakens one; it proposes those changes in its report instead.

Both files live in `.claude/pipeline/verification/` in your repo:

```
.claude/pipeline/
├── config.json                  # detected commands (per clone)
├── context/                     # saved --spec sources (per run)
├── PLAN.md, ADR.md              # working files (per run)
└── verification/
    ├── PROPERTY-DISCOVERY.md    # method and pattern checklist (kept, yours to edit)
    └── INVARIANTS.md            # registry of invariants and their tests (kept, grows)
```

- **Never checked in.** Like the rest of `.claude/pipeline/`, the folder is listed in your clone's `info/exclude`. Your repo and its `.gitignore` aren't touched. The PR body carries the property table and mutation results for reviewers.
- **Seeded once, then yours.** On the first run, the pipeline copies generic versions from the plugin. Add your codebase's own patterns and examples to `PROPERTY-DISCOVERY.md`; later runs use your copy and never overwrite it.
- **Per clone.** Since it isn't committed, each clone has its own registry. To share one across a team, copy the files somewhere you choose; if a repo already commits its own invariant docs (for example `docs/verification/INVARIANTS.md` or rules in `AGENTS.md`), every agent reads them as well, but the pipeline never edits them.
- **Worktrees** share the main checkout's folder through a symlink, so rows added in any worktree land in one place.

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
